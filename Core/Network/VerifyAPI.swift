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

    func handshake() async throws -> HandshakeResponse {
        let headers = await AppAttestService.shared.attestationHeaders()
        var req = HandshakeRequest()
        req.fcmToken = AppPrefs.apnsToken   // APNs hex token → device_tokens tablosuna upsert
        return try await client.post("api/Verify/handshake", body: req, headers: headers)
    }

    func loginHandshake() async throws -> LoginHandshakeResponse {
        let headers = await AppAttestService.shared.attestationHeaders()
        var req = HandshakeRequest()
        req.fcmToken = AppPrefs.apnsToken
        return try await client.post("api/Verify/login-handshake", body: req, headers: headers)
    }

    // MARK: - Register

    func register(_ request: RegistrationRequest) async throws -> EncryptedTicketResponse {
        try await client.post("api/Verify/register", body: request)
    }

    func demoRegister(_ request: DemoRegisterRequest) async throws -> EncryptedTicketResponse {
        try await client.post("api/Verify/demo-register", body: request)
    }

    // MARK: - Login / Revoke

    /// Relay /login MOBİLE'a başarıda `{}` döner (encrypted_response partner callback'ine gider,
    /// app'e DEĞİL) → gövde decode edilmez (postNoContent). Hata gövdeleri APIClient.apiError'da ele alınır.
    func login(_ request: LoginRequest) async throws {
        let headers = await AppAttestService.shared.attestationHeaders()
        try await client.postNoContent("api/Verify/login", body: request, headers: headers)
    }

    func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        let headers = await AppAttestService.shared.attestationHeaders()
        return try await client.post("api/Verify/revoke", body: request, headers: headers)
    }

    // MARK: - Partner / PoP

    func partnerInfo(nonce: String) async throws -> PartnerInfoResponse {
        let headers = await AppAttestService.shared.attestationHeaders()
        return try await client.get("api/PartnerRequest/info/\(nonce)", headers: headers)
    }

    func cancelPop(_ request: PopCancelRequest) async throws {
        try await client.postNoContent("api/pop/cancel", body: request)
    }

    // MARK: - Public config

    func appConfig() async throws -> AppConfigResponse {
        try await client.get("api/public/app-config")
    }

    // MARK: - Backup PIN (TCKN'siz kimlikler)

    /// PIN + UUID → person_id. Android `deriveBackupPersonId` paritesi. Sunucu kota (10/gün/UUID)
    /// ve attestation'a tabidir; 429 = kota, 403 = attestation. PIN/UUID saklanmaz.
    func deriveBackupPersonId(_ request: DerivePinRequest) async throws -> DerivePinResponse {
        try await client.post("api/Backup/derive-person-id", body: request)
    }

    /// İstemci sarılı DEK'i açınca çağırır → kota sıfırlanır. Android `resetBackupQuota` paritesi.
    func resetBackupQuota(_ request: DerivePinRequest) async throws {
        try await client.postNoContent("api/Backup/reset-quota", body: request)
    }

    // MARK: - KVKK

    func withdrawConsent(_ request: KvkkWithdrawRequest) async throws {
        try await client.postNoContent("api/kvkk/consent/withdraw", body: request)
    }

    /// Kart engelleme — attestation card_id'ye BAĞLI gönderilir. Assertion yalnız bu card_id için
    /// geçerli olur; araya girip gövdedeki card_id'yi başkasınınkiyle takas etmek sunucuda RED alır.
    func blockCard(_ request: KvkkBlockCardRequest) async throws {
        let headers = await AppAttestService.shared.attestationHeaders(boundTo: request.cardId)
        try await client.postNoContent("api/kvkk/block-card", body: request, headers: headers)
    }

    /// Aydınlatma metni (consent ekranı "Aydınlatma Metnini Oku"). format=text → `{text}`.
    func privacyNotice(format: String = "text") async throws -> PrivacyNoticeResponse {
        try await client.get("api/kvkk/privacy-notice?format=\(format)")
    }

}
