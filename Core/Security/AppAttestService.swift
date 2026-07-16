import Foundation
import DeviceCheck
import CryptoKit

/// Apple App Attest istemcisi — Android `util/IntegrityManagerHelper` (Play Integrity) eşdeğeri (Aşama 6).
///
/// Cihazın gerçek bir Apple donanımı olduğunu sunucuya kanıtlar. İki faz:
/// - **Enroll (tek sefer):** `generateKey` → sunucudan challenge → `attestKey` → `/appattest/enroll`.
///   Sunucu attestation'ı doğrular, public key + sayaç saklar.
/// - **Assert (her korunan çağrı):** sunucudan taze challenge → `generateAssertion` → korunan isteğe
///   `X-App-Attest` başlığıyla iliştirilir; sunucu imzayı + sayacı doğrular.
///
/// Korunan uçlar (relay'de doğrulanır): handshake, login-handshake, login, revoke, partner-info.
/// (Register relay'de değil enclave'e proxy'lenir → el sıkışma assertion'ı + nonce bağı ile örtülür.)
///
/// Simülatör / desteklenmeyen cihaz → `isSupported=false` → token üretilmez (graceful). Sunucu
/// `APP_ATTEST_ENABLED` bayrağına göre karar verir (Android null-token toleransıyla aynı).
actor AppAttestService {
    static let shared = AppAttestService()

    private let service = DCAppAttestService.shared

    /// Korunan çağrılara eklenecek başlıklar. Daima `X-Client-Platform: ios`; mümkünse `X-App-Attest`.
    ///
    /// - Parameter cardId: Verilirse assertion bu card_id'ye BAĞLANIR
    ///   (`clientDataHash = SHA256(challenge ‖ card_id)`); sunucu birebir aynısını hesaplar.
    ///   `nil` → eski davranış (`SHA256(challenge)`), diğer tüm korunan uçlar bunu kullanır.
    func attestationHeaders(boundTo cardId: String? = nil) async -> [String: String] {
        var headers = ["X-Client-Platform": "ios"]
        guard service.isSupported else {
            Log.info("App Attest desteklenmiyor (simülatör/eski cihaz) — token atlanıyor", category: .crypto)
            return headers
        }
        do {
            let keyId = try await ensureEnrolledKeyId()
            let challenge = try await fetchChallenge()
            let hash = cardId.map { AttestationBinding.clientDataHash(challenge: challenge, cardId: $0) }
                ?? clientDataHash(challenge)
            let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
            let token = AppAttestToken(keyId: keyId, challenge: challenge, assertion: assertion.base64EncodedString())
            if let json = try? JSONEncoder().encode(token) {
                headers["X-App-Attest"] = json.base64EncodedString()
            }
            Log.info("App Attest assertion üretildi", category: .crypto)
        } catch {
            Log.warning("App Attest token üretilemedi: \(error) — graceful devam", category: .crypto)
        }
        return headers
    }

    // MARK: - Enroll

    private func ensureEnrolledKeyId() async throws -> String {
        // Zaten enroll'lu anahtar varsa yeniden kullan.
        if let existing = SecureStore.getAppAttestKeyId(), AppPrefs.appAttestEnrolled {
            return existing
        }
        // Enroll'lu DEĞİL → TAZE anahtar üret. ⚠️ `attestKey` Apple'da anahtar başına YALNIZCA BİR KEZ
        // çağrılabilir → önceki başarısız denemenin (enroll reddedilmiş) anahtarını ASLA yeniden
        // attest etme; o anahtarı bırak, yenisini üret. KeyId yalnızca enroll BAŞARILI olunca saklanır.
        let keyId = try await service.generateKey()
        let challenge = try await fetchChallenge()
        let hash = clientDataHash(challenge)
        let attestation = try await service.attestKey(keyId, clientDataHash: hash)
        try await enroll(keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge)
        SecureStore.saveAppAttestKeyId(keyId)
        AppPrefs.appAttestEnrolled = true
        Log.info("App Attest anahtarı enroll edildi", category: .crypto)
        return keyId
    }

    // MARK: - Sunucu çağrıları (bootstrap — kendileri attestation taşımaz)

    private func fetchChallenge() async throws -> String {
        let resp: AppAttestChallengeResponse = try await APIClient.shared.get("api/Verify/appattest/challenge")
        return resp.challenge
    }

    private func enroll(keyId: String, attestation: String, challenge: String) async throws {
        try await APIClient.shared.postNoContent(
            "api/Verify/appattest/enroll",
            body: AppAttestEnrollRequest(keyId: keyId, attestation: attestation, challenge: challenge))
    }

    /// clientDataHash = SHA256(challenge UTF8). Sunucu birebir aynısını üretir.
    private nonisolated func clientDataHash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }
}
