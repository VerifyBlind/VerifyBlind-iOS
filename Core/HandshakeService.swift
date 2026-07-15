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
/// `AppAttestService.attestationHeaders()` ile EKLENİR (relay doğrular). Enclave attestation'ı
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

    /// Throw ETMEYEN attestation sondası — launch-gate + Security ekranı ortak kullanır.
    /// Yalnız GERÇEK doğrulama hatasında `.failed` döner; ağ/HTTP hatasında `.unreachable` (fail-open,
    /// onaylı karar: erişilemezlik BLOKLAMAZ). Başarıda `last_*` teşhis prefs'ini de tazeler.
    func probeAttestation() async -> AttestOutcome {
        do {
            let resp = try await VerifyAPI.shared.loginHandshake()
            let result = AttestationVerifier.verify(
                attestationBase64: resp.attestationDocument ?? "",
                pcr0Signature: resp.pcr0Signature)
            if result.isValid {
                recordAttestationDiagnostics(result: result)
                return .verified(pcr0: result.pcr0 ?? "N/A")
            }
            let kind = result.failureKind ?? .integrity
            return .failed(kind: kind, message: kind.userMessage)
        } catch {
            Log.warning("Attestation sondası ağ hatası (bloklanmıyor): \(error.localizedDescription)", category: .flow)
            return .unreachable
        }
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
