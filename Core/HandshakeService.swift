import Foundation

/// El sıkışma durumu yönetimi — Android `MainViewModel` handshake state'i (enclavePubKey, nonce,
/// timestamp, nonceSignature, challenges, 5dk TTL) eşdeğeri.
///
/// ⚠️ Attestation/PCR0 doğrulaması Aşama 4'te YAPILMAZ (dev-skip — Android dev paritesi). Gerçek
/// AWS Nitro attestation verify + App Attest integrity token Aşama 6'ya bırakıldı. Dev/staging
/// sunucusuna güvenilir; enclavePubKey doğrudan kullanılır.
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

    /// Register el sıkışması — HER kayıtta taze nonce + challenges gerekir (cache YOK).
    func performRegisterHandshake() async throws -> Session {
        Log.info("Register handshake başlatılıyor", category: .flow)
        let resp = try await VerifyAPI.shared.handshake()
        guard let pub = resp.enclavePubKey, !pub.isEmpty else {
            throw HandshakeError.missingEnclaveKey
        }
        let s = Session(
            enclavePubKey: pub,
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

    /// Login el sıkışması — yalnız enclavePubKey'i tazeler (login nonce QR'dan gelir). TTL içinde cache.
    @discardableResult
    func ensureLoginHandshake() async throws -> String {
        if isFresh, let s = session { return s.enclavePubKey }
        Log.info("Login handshake başlatılıyor", category: .flow)
        let resp = try await VerifyAPI.shared.loginHandshake()
        guard let pub = resp.enclavePubKey, !pub.isEmpty else {
            throw HandshakeError.missingEnclaveKey
        }
        session = Session(enclavePubKey: pub, nonce: "", timestamp: 0, nonceSignature: "",
                          challenges: [], completedAt: Date())
        Log.info("Login handshake tamam", category: .flow)
        return pub
    }
}

enum HandshakeError: Error, LocalizedError {
    case missingEnclaveKey

    var errorDescription: String? {
        switch self {
        case .missingEnclaveKey: return L.t("error_enclave_key_missing")
        }
    }
}
