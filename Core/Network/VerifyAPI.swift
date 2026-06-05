import Foundation

/// VerifyBlind Relay API'sinin tipli cephesi — Android `KimlikApi` (Retrofit) eşdeğeri.
///
/// Path'ler host-root'a görelidir (`APIClient` origin'e ekler). Android'de bazı uçlar
/// `/api/Verify/` tabanına göreliydi (handshake/register/login/revoke), bazıları host-root'tan
/// mutlaktı (pop/partner/public/kvkk) — burada hepsi tam path ile ifade edilir.
///
/// Aşama 1'de yalnızca `appConfig()` ve `handshake()` self-test'te kullanılır; geri kalanı
/// Android sözleşmesinin tam portudur (Aşama 4 register/login akışları için hazır).
struct VerifyAPI {
    static let shared = VerifyAPI()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    // MARK: - Handshake

    func handshake(integrityToken: String? = nil) async throws -> HandshakeResponse {
        try await client.post("api/Verify/handshake", body: HandshakeRequest(), headers: integrityHeader(integrityToken))
    }

    func loginHandshake(integrityToken: String? = nil) async throws -> LoginHandshakeResponse {
        try await client.post("api/Verify/login-handshake", body: HandshakeRequest(), headers: integrityHeader(integrityToken))
    }

    // MARK: - Register

    func register(_ request: RegistrationRequest) async throws -> EncryptedTicketResponse {
        try await client.post("api/Verify/register", body: request)
    }

    func demoRegister(_ request: DemoRegisterRequest) async throws -> EncryptedTicketResponse {
        try await client.post("api/Verify/demo-register", body: request)
    }

    // MARK: - Login / Revoke

    func login(_ request: LoginRequest) async throws -> LoginResponse {
        try await client.post("api/Verify/login", body: request)
    }

    func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        try await client.post("api/Verify/revoke", body: request)
    }

    // MARK: - Partner / PoP

    func partnerInfo(nonce: String, integrityToken: String? = nil) async throws -> PartnerInfoResponse {
        try await client.get("api/PartnerRequest/info/\(nonce)", headers: integrityHeader(integrityToken))
    }

    func cancelPop(_ request: PopCancelRequest) async throws {
        try await client.postNoContent("api/pop/cancel", body: request)
    }

    // MARK: - Public config

    func appConfig() async throws -> AppConfigResponse {
        try await client.get("api/public/app-config")
    }

    // MARK: - KVKK

    func withdrawConsent(_ request: KvkkWithdrawRequest) async throws {
        try await client.postNoContent("api/kvkk/consent/withdraw", body: request)
    }

    func blockCard(_ request: KvkkBlockCardRequest) async throws {
        try await client.postNoContent("api/kvkk/block-card", body: request)
    }

    // MARK: - Yardımcı

    /// Play Integrity (Android) başlığı. iOS'ta App Attest eşdeğeri Aşama 6'da gelir; şimdilik opsiyonel.
    private func integrityHeader(_ token: String?) -> [String: String] {
        guard let token, !token.isEmpty else { return [:] }
        return ["X-Play-Integrity": token]
    }
}
