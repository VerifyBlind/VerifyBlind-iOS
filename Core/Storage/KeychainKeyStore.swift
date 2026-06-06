import Foundation
import Security
import LocalAuthentication

/// Android `crypto/CryptoUtils.kt` Keystore kısmı + `util/BiometricHelper.kt` iOS portu.
///
/// İki RSA-2048 anahtar Keychain'de yaşar (Android `AndroidKeyStore` eşdeğeri):
/// - **User key** — biyometrik-kapılı (`.userPresence`), ticket'in AES anahtarını çözer.
///   Android `USER_KEY_ALIAS` (`setUserAuthenticationRequired(true)`, per-use auth) paritesi.
/// - **History key** — biyometriksiz, history title/description çözer. Android `HISTORY_KEY_ALIAS`.
///
/// Decrypt **OAEP-SHA1/MGF1-SHA1** (Android `keystoreOaepSpec` + sunucu user-key sarması). iOS Secure
/// Enclave RSA desteklemediği için anahtarlar normal Keychain'de access-control ile yaşar; biyometrik
/// gating kullanım anında (private key op) tetiklenir — Android per-use auth ile aynı davranış.
enum KeychainKeyStore {

    private static let userKeyTag    = Data("app.verifyblind.ios.userkey.v1".utf8)
    private static let historyKeyTag = Data("app.verifyblind.ios.historykey.v1".utf8)

    // MARK: - User key (biyometrik)

    /// Yoksa üretir, SPKI base64 public key döner (Android `ensureKeyExists` → `publicKey.encoded`).
    @discardableResult
    static func ensureUserKey() throws -> String {
        try ensureKey(tag: userKeyTag, biometric: true)
    }

    /// Ticket'in AES anahtarını çözer. Face ID/passcode promptu (Android `BiometricPrompt` + CryptoObject).
    static func decryptWithUserKey(_ cipherBase64: String, reason: String) async throws -> String {
        let context = LAContext()
        try await authenticate(context: context, reason: reason)
        let priv = try loadPrivateKey(tag: userKeyTag, context: context)
        return try CryptoUtils.rsaDecrypt(cipherBase64, privateKey: priv, algorithm: .rsaEncryptionOAEPSHA1)
    }

    /// Android `deleteKey()` — kart silindiğinde user key kaldırılır.
    static func deleteUserKey() {
        delete(tag: userKeyTag)
    }

    // MARK: - History key (biyometriksiz)

    @discardableResult
    static func ensureHistoryKey() throws -> String {
        try ensureKey(tag: historyKeyTag, biometric: false)
    }

    /// Android `rsaDecryptHistory` — prompt yok.
    static func decryptWithHistoryKey(_ cipherBase64: String) throws -> String {
        let priv = try loadPrivateKey(tag: historyKeyTag, context: nil)
        return try CryptoUtils.rsaDecrypt(cipherBase64, privateKey: priv, algorithm: .rsaEncryptionOAEPSHA1)
    }

    // MARK: - Çekirdek

    private static func ensureKey(tag: Data, biometric: Bool) throws -> String {
        // Mevcut private key varsa public'i türet (private key materyaline dokunmaz → prompt yok).
        if let existing = try? loadPrivateKey(tag: tag, context: nil),
           let pub = SecKeyCopyPublicKey(existing),
           let spki = RSAKey.spkiBase64(of: pub) {
            return spki
        }
        let priv = try generateKey(tag: tag, biometric: biometric)
        guard let pub = SecKeyCopyPublicKey(priv), let spki = RSAKey.spkiBase64(of: pub) else {
            throw KeychainKeyStoreError.publicKeyExtractionFailed
        }
        Log.info("KeychainKeyStore: \(biometric ? "user" : "history") key üretildi", category: .crypto)
        return spki
    }

    private static func generateKey(tag: Data, biometric: Bool) throws -> SecKey {
        var privAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
        ]
        if biometric {
            var acErr: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,                 // biyometri VEYA passcode (Android setUserAuthenticationRequired(true) eşi)
                &acErr
            ) else {
                throw KeychainKeyStoreError.generationFailed("SecAccessControl: \(cfErr(acErr))")
            }
            privAttrs[kSecAttrAccessControl as String] = access
        } else {
            privAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String:   privAttrs,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw KeychainKeyStoreError.generationFailed(cfErr(error))
        }
        return priv
    }

    private static func loadPrivateKey(tag: Data, context: LAContext?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String:            kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String:      kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:     kSecAttrKeyClassPrivate,
            kSecReturnRef as String:        true,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            throw status == errSecItemNotFound
                ? KeychainKeyStoreError.keyNotFound
                : KeychainKeyStoreError.fetchFailed(status)
        }
        return (item as! SecKey)
    }

    private static func delete(tag: Data) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// LAContext'i `.deviceOwnerAuthentication` (biyometri veya passcode) ile değerlendirir; başarılı
    /// context ile çekilen anahtar `.userPresence` kısıtını ek prompt olmadan karşılar.
    private static func authenticate(context: LAContext, reason: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: KeychainKeyStoreError.authFailed(error?.localizedDescription ?? "iptal edildi"))
                }
            }
        }
    }

    private static func cfErr(_ e: Unmanaged<CFError>?) -> String {
        guard let err = e?.takeRetainedValue() else { return "unknown" }
        return (CFErrorCopyDescription(err) as String?) ?? "unknown"
    }
}

enum KeychainKeyStoreError: Error, CustomStringConvertible {
    case generationFailed(String)
    case publicKeyExtractionFailed
    case keyNotFound
    case authFailed(String)
    case fetchFailed(OSStatus)

    var description: String {
        switch self {
        case .generationFailed(let m):     return "generationFailed(\(m))"
        case .publicKeyExtractionFailed:   return "publicKeyExtractionFailed"
        case .keyNotFound:                 return "keyNotFound"
        case .authFailed(let m):           return "authFailed(\(m))"
        case .fetchFailed(let s):          return "fetchFailed(OSStatus \(s))"
        }
    }

    var localizedDescription: String { description }
}
