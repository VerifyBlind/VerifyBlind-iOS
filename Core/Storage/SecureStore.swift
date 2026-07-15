import Foundation
import Security

/// Android `util/SecureStore.kt` (EncryptedSharedPreferences) iOS Keychain portu.
///
/// Hassas tanımlayıcıları saklar: `personId` (SHA256(TCKN) / server), `cardId` (SHA256(SOD) / server),
/// `fcm_token`. Keychain `kSecClassGenericPassword`, `AfterFirstUnlockThisDeviceOnly` erişim.
enum SecureStore {
    private static let service = "app.verifyblind.ios.securestore"

    static func saveIds(personId: String, cardId: String) {
        set("personId", personId)
        set("cardId", cardId)
    }

    static func getPersonId() -> String? { get("personId") }
    static func getCardId() -> String? { get("cardId") }

    static func saveFcmToken(_ token: String) { set("fcm_token", token) }
    static func getFcmToken() -> String? { get("fcm_token") }

    /// App Attest anahtar kimliği (gizli değil ama cihaza-özel; iCloud/yedek dışında tutulur). Aşama 6.
    static func saveAppAttestKeyId(_ keyId: String) { set("appattest_key_id", keyId) }
    static func getAppAttestKeyId() -> String? { get("appattest_key_id") }

    /// Android `clear()` — kart silindiğinde / reset'te.
    static func clear() {
        for account in ["personId", "cardId", "fcm_token", "appattest_key_id"] { delete(account) }
    }

    // MARK: - Keychain çekirdek

    private static func set(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.error("SecureStore.set başarısız (\(account)): OSStatus \(addStatus)", category: .crypto)
            }
        } else if status != errSecSuccess {
            Log.error("SecureStore.update başarısız (\(account)): OSStatus \(status)", category: .crypto)
        }
    }

    private static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
