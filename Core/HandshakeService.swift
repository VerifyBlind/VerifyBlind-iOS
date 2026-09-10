import Foundation

/// Launch-gate + Security ekranı için attestation sonda sonucu.
enum AttestOutcome {
    case verified(pcr0: String)
    case failed(kind: AttestFailureKind, message: String)
    case unreachable   // ağ/sunucu erişilemez veya App Attest altyapısı → BLOKLAMA
}

/// El sıkışma durumu yönetimi — Android `MainViewModel` handshake state'i (enclavePubKey, nonce,
/// timestamp, nonceSignature, challenges, 5dk TTL) eşdeğeri.
///
/// App Attest (cihaz → sunucu) Aşama 6'da `VerifyAPI.handshake`/`loginHandshake` içinden
/// `AttestedRequest.perform` ile EKLENİR (relay doğrular; çağrılar sıraya girer). Enclave attestation'ı
/// (sunucu → cihaz) HER handshake'te `AttestationVerifier` ile TAM doğrulanır (fail-closed; AWS Root
/// CA + PCR0 developer imzası + COSE_Sign1) — dev-skip/bypass YOK. Güvenlik ekranı teşhisi bu
/// doğrulama sonucundan gelir (App Attest ortamından DEĞİL — ikisi bağımsızdır).
actor HandshakeService {
    static let shared = HandshakeService()

    struct Session {
        let enclavePubKey: String
        let nonce: String
        let timestamp: Int64
        let nonceSignature: String
        let challenges: [Int]
        let completedAt: Date
    }

    private var session: Session?
    private let ttl: TimeInterval = 5 * 60

    private var isFresh: Bool {
        guard let s = session else { return false }
        return Date().timeIntervalSince(s.completedAt) < ttl
    }

    func performRegisterHandshake() async throws -> Session {
        Log.info("Register handshake başlatılıyor", category: .flow)
        let resp = try await VerifyAPI.shared.handshake()
        let verifiedPub = try verifiedEnclaveKey(from: resp.attestationDocument,
                                                  pcr0Signature: resp.pcr0Signature)
        let s = Session(
            enclavePubKey: verifiedPub,
            nonce: resp.nonce,
            timestamp: resp.timestamp,
            nonceSignature: resp.nonceSignature,
            challenges: resp.challenges ?? [],
            completedAt: Date()
        )
        session = s
        Log.info("Register handshake tamam (challenges=\(s.challenges.count))", category: .flow)
        return s
    }

    @discardableResult
    func ensureLoginHandshake() async throws -> String {
        if isFresh, let s = session { return s.enclavePubKey }
        Log.info("Login handshake başlatılıyor", category: .flow)
        let resp = try await VerifyAPI.shared.loginHandshake()
        let verifiedPub = try verifiedEnclaveKey(from: resp.attestationDocument,
                                                  pcr0Signature: resp.pcr0Signature)
        session = Session(enclavePubKey: verifiedPub, nonce: "", timestamp: 0, nonceSignature: "",
                          challenges: [], completedAt: Date())
        Log.info("Login handshake tamam", category: .flow)
        return verifiedPub
    }

    /// `.integrity` hatasında kaç kez yeniden denenir ve aralarda ne kadar beklenir.
    ///
    /// NEDEN VAR (2026-09-10, `VERIFYBLIND-IOS-46`, üçüncü tekrar): enclave'in attestation
    /// belgesindeki leaf sertifika 3 saat ömürlü ve AWS onu ancak vadesine ~15 dk kala
    /// döndürüyor. O dar pencereye denk gelen açılış, sunucu tamamen sağlıklıyken bile
    /// süresi dolmuş bir zincir görüp uygulamayı bloke ediyordu; kullanıcının tek çaresi
    /// "Yeniden Dene"ye basmaktı ve basınca DÜZELİYORDU — yani kurtarma zaten çalışıyordu,
    /// yalnızca elle tetikleniyordu. Kullanıcıya kendi kendine düzelecek bir hatayı
    /// göstermek gereksiz.
    ///
    /// Yeniden deneme İŞE YARAR, çünkü sonda her seferinde TAZE bir `loginHandshake`
    /// çağırıyor: istemcide saklanan bir belge yok, dolayısıyla "eskiyi sil" diye bir adım
    /// da gerekmiyor — ikinci çağrı sunucudan yeni mint edilmiş belgeyi alır.
    ///
    /// ⚠️ GÜVENLİK DENGESİ: bu, gerçek bir kurcalama/MITM denemesini de 2 kez tekrar eder
    /// ve kullanıcıya ~6 sn geç bildirir. Kabul edildi (kullanıcı kararı, 2026-09-11) çünkü
    /// blok NİHAYETİNDE korunuyor — yeniden denemeler tükenince fail-closed davranış aynen
    /// sürüyor. Karşılığında, kendi kendine düzelen bir arıza kullanıcıya hiç yansımıyor.
    /// Hangi hatanın tekrarla düzeldiği Sentry'de görünür (aşağıdaki `Log.warning`).
    static let integrityRetryCount = 2
    private static let integrityRetryDelay: UInt64 = 3_000_000_000   // 3 sn

    /// Bu hata bir kez daha denenmeli mi?
    ///
    /// Saf fonksiyon — cihaz, ağ ve zamanlayıcı olmadan test edilebilsin diye ayrıldı:
    /// yeniden denemenin DOĞRU türde çalıştığı, asıl güvenlik sözleşmesi.
    static func shouldRetry(kind: AttestFailureKind, attempt: Int) -> Bool {
        // `.authorization` YENİDEN DENENMEZ: PCR0 imzasının yokluğu ya da eşleşmemesi bir
        // deploy/sürüm boşluğudur (bkz. pcr0_signatures.json) ve saniyeler içinde
        // kendiliğinden düzelmez — beklemek yalnız kullanıcıyı oyalar. Yeniden denenen
        // tek tür, geçici olabilen `.integrity`.
        guard kind == .integrity else { return false }
        return attempt < integrityRetryCount
    }

    /// Throw ETMEYEN attestation sondası — launch-gate + Security ekranı ortak kullanır.
    /// Yalnız GERÇEK doğrulama hatasında `.failed` döner; ağ/HTTP hatasında `.unreachable`
    /// (fail-open, onaylı karar: erişilemezlik BLOKLAMAZ). Başarıda `last_*` teşhis
    /// prefs'ini de tazeler. `.integrity` hataları önce yeniden denenir (bkz. shouldRetry).
    func probeAttestation() async -> AttestOutcome {
        var lastFailure: (kind: AttestFailureKind, reason: String)?

        for attempt in 0...Self.integrityRetryCount {
            do {
                let resp = try await VerifyAPI.shared.loginHandshake()
                let result = AttestationVerifier.verify(
                    attestationBase64: resp.attestationDocument ?? "",
                    pcr0Signature: resp.pcr0Signature)
                if result.isValid {
                    if attempt > 0 {
                        // GEÇİCİ OLDUĞUNU KAYDET. Bu satır olmadan yeniden deneme, arızayı
                        // düzeltmek yerine GİZLER: sunucu tarafında gerçekten bozulan bir şey
                        // varsa hiçbir iz kalmaz ve sorun ancak kalıcı hâle gelince fark edilir.
                        Log.warning("Attestation \(attempt). denemede DÜZELDİ (ilk hata: \(lastFailure?.reason ?? "?")) — geçici arıza",
                                    category: .flow)
                    }
                    recordAttestationDiagnostics(result: result)
                    return .verified(pcr0: result.pcr0 ?? "N/A")
                }

                let kind = result.failureKind ?? .integrity
                let reason = result.failReason ?? "sebep yok"
                lastFailure = (kind, reason)

                if !Self.shouldRetry(kind: kind, attempt: attempt) { break }

                Log.warning("Attestation REDDETTİ (\(kind)): \(reason) — yeniden deneniyor (\(attempt + 1)/\(Self.integrityRetryCount))",
                            category: .flow)
                try? await Task.sleep(nanoseconds: Self.integrityRetryDelay)
            } catch {
                // Ağ/HTTP hatası: onaylı karar gereği BLOKLAMAZ ve burada yeniden de
                // denenmez — `APIClient` kendi yeniden denemesini zaten yapıyor.
                Log.warning("Attestation sondası ağ hatası (bloklanmıyor)", error: error, category: .flow)
                return .unreachable
            }
        }

        guard let failure = lastFailure else { return .unreachable }
        // SEBEBİ KAYDET. Kullanıcı yalnız yerelleştirilmiş genel mesajı görüyor ("güvenli
        // bağlantı doğrulanamadı"); hangi adımın düştüğü — COSE imzası mı, CA zinciri mi,
        // PCR0 mı — yalnız `failReason` içinde. Bu satır olmadığı için 2026-08-26'da sunucu
        // taze ve geçerli belge servis ederken uygulama açılmadı ve elimizde tek bir iz yoktu.
        Log.error("Attestation sondası REDDETTİ (\(failure.kind)) — \(Self.integrityRetryCount) yeniden denemeye rağmen: \(failure.reason)",
                  category: .flow)
        return .failed(kind: failure.kind, message: failure.kind.userMessage)
    }

    /// Attestation belgesini doğrular; başarılıysa enclave public key'i döner.
    /// Başarısızsa `HandshakeError.attestationFailed` fırlatır.
    private func verifiedEnclaveKey(from attestationDoc: String?, pcr0Signature: String?) throws -> String {
        // PCR0/attestation HER ZAMAN tam doğrulanır — dev-skip / relay-anahtarı fallback'i YOK, bypass YOK.
        let result = AttestationVerifier.verify(
            attestationBase64: attestationDoc ?? "",
            pcr0Signature: pcr0Signature
        )
        if result.isValid, let pub = result.enclavePubKey, !pub.isEmpty {
            recordAttestationDiagnostics(result: result)   // teşhis yalnız doğrulama geçince güncellenir
            return pub
        }
        throw HandshakeError.attestationFailed(result.failReason ?? "Attestation doğrulaması başarısız")
    }

    /// Güvenlik ekranı (Sistem Güvenliği) teşhislerini attestation DOĞRULAMA sonucundan yazar —
    /// Android `MainViewModel` `last_*` prefs paritesi (birebir: `isVerified = isValid && !isMock`).
    /// PCR0 doğrulanmış belgeden gelir; `isMock` yalnızca `AttestationVerifier` mock belge işaretlerse
    /// true olur (gerçek AWS Nitro'da hep false). App Attest ORTAMI burada KULLANILMAZ — o Apple cihaz
    /// attestation'ıdır, enclave attestation'ından bağımsızdır (eski hatalı bağ kaldırıldı).
    private func recordAttestationDiagnostics(result: AttestationVerifier.VerificationResult) {
        AppPrefs.lastPcr0 = result.pcr0 ?? "N/A"
        AppPrefs.lastIsMock = result.isMockDocument
        AppPrefs.lastHardwareVerified = result.isValid && !result.isMockDocument
        AppPrefs.lastAttestationTime = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

enum HandshakeError: Error, LocalizedError {
    case missingEnclaveKey
    case attestationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingEnclaveKey:         return L.t("error_enclave_key_missing")
        case .attestationFailed(let r):  return "\(L.t("error_enclave_key_missing")): \(r)"
        }
    }
}
