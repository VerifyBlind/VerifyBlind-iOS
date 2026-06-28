import Foundation

/// El sıkışma durumu yönetimi — Android `MainViewModel` handshake state'i (enclavePubKey, nonce,
/// timestamp, nonceSignature, challenges, 5dk TTL) eşdeğeri.
///
/// App Attest (cihaz → sunucu) Aşama 6'da `VerifyAPI.handshake`/`loginHandshake` içinden
/// `AppAttestService.attestationHeaders()` ile EKLENİR (relay doğrular). ⚠️ Enclave PCR0 imza
/// doğrulaması (sunucu → cihaz) hâlâ dev-skip: dev/staging sunucusuna güvenilir, enclavePubKey
/// doğrudan kullanılır (ayrı sertleştirme görevi). Güvenlik ekranı teşhisi enclave attestation'dan
/// gelir (App Attest'ten DEĞİL).
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
        recordAttestationDiagnostics(attestationDocument: resp.attestationDocument)
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
        recordAttestationDiagnostics(attestationDocument: resp.attestationDocument)
        Log.info("Login handshake tamam", category: .flow)
        return verifiedPub
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
            return pub
        }
        throw HandshakeError.attestationFailed(result.failReason ?? "Attestation doğrulaması başarısız")
    }

    /// Güvenlik ekranı (Sistem Güvenliği) teşhislerini el sıkışma yanıtından yazar — Android
    /// `MainViewModel`'in `last_*` prefs paritesi. PCR0 attestation belgesinden çıkarılır.
    private func recordAttestationDiagnostics(attestationDocument: String?) {
        let pcr0 = EnclaveAttestation.extractPcr0(fromBase64: attestationDocument)
        let hasRealDoc = (pcr0 != nil)
        let isMock = (Config.appAttestEnvironment == .development) || !hasRealDoc
        AppPrefs.lastPcr0 = pcr0 ?? "N/A"
        AppPrefs.lastIsMock = isMock
        AppPrefs.lastHardwareVerified = hasRealDoc && !isMock
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
