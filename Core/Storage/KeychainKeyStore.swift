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

    /// Public key cache (biyometriksiz generic-password item) servis adı. RSA anahtarı normal Keychain'de
    /// `.userPresence` ile yaşadığı için `SecKeyCopyPublicKey` korumalı materyale dokunur ve Face ID promptu
    /// çıkar — Android'de public key sertifikadan biyometriksiz okunduğu için bu prompt yok. Pariteyi sağlamak
    /// için public key (gizli değil) burada ayrı, biyometriksiz cache'lenir.
    private static let pubCacheService = "app.verifyblind.ios.pubkeycache.v1"

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
        // Eski kurulum migrasyonu: public key henüz cache'lenmemişse, kimliği DOĞRULANMIŞ context ile
        // türetip cache'le (ek prompt yok). Böylece bir sonraki kayıt MRZ öncesi prompt çıkarmaz.
        if cachedPublicKey(tag: userKeyTag) == nil,
           let pub = SecKeyCopyPublicKey(priv), let spki = RSAKey.spkiBase64(of: pub) {
            cachePublicKey(spki, tag: userKeyTag)
        }
        return try CryptoUtils.rsaDecrypt(cipherBase64, privateKey: priv, algorithm: .rsaEncryptionOAEPSHA1)
    }

    /// Holder-of-key (Y-4): TEK Face ID/passcode promptuyla hem ticket'in AES anahtarını çözer hem de
    /// `message`'i user key ile RSA-PSS/SHA-256 imzalar. LAContext bir kez doğrulanır; her iki
    /// private-key işlemi aynı doğrulanmış context'le yapılır (ek prompt yok). Android'de user key
    /// auth-per-use olduğundan iki prompt gerekir; iOS'ta LAContext yeniden kullanımı tek prompta indirir.
    static func decryptAndSign(_ cipherBase64: String, message: String, reason: String) async throws -> (aesKey: String, signatureBase64: String) {
        let context = LAContext()
        try await authenticate(context: context, reason: reason)
        let priv = try loadPrivateKey(tag: userKeyTag, context: context)
        // Eski kurulum migrasyonu: public key cache yoksa, DOĞRULANMIŞ context ile türetip cache'le (ek prompt yok).
        if cachedPublicKey(tag: userKeyTag) == nil,
           let pub = SecKeyCopyPublicKey(priv), let spki = RSAKey.spkiBase64(of: pub) {
            cachePublicKey(spki, tag: userKeyTag)
        }
        let aesKey = try CryptoUtils.rsaDecrypt(cipherBase64, privateKey: priv, algorithm: .rsaEncryptionOAEPSHA1)
        let signature = try CryptoUtils.rsaSignPSS(message, privateKey: priv)
        return (aesKey, signature)
    }

    /// Android `deleteKey()` — kart silindiğinde user key kaldırılır.
    static func deleteUserKey() {
        delete(tag: userKeyTag)
        deleteCachedPublicKey(tag: userKeyTag)
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

    /// Reset/Verilerimi Sil — history key kaldırılır (Android `deleteHistoryKey`).
    static func deleteHistoryKey() {
        delete(tag: historyKeyTag)
        deleteCachedPublicKey(tag: historyKeyTag)
    }

    // MARK: - Çekirdek

    private static func ensureKey(tag: Data, biometric: Bool) throws -> String {
        // 1) Cache'lenmiş public key varsa korumalı private key'e DOKUNMADAN dön (Android sertifika paritesi:
        //    public key biyometriksiz okunur, prompt yok).
        if let cached = cachedPublicKey(tag: tag) {
            return cached
        }
        // 2) Anahtar var ama cache yok (bu fix'ten ÖNCE üretilmiş eski kurulum): public'i türetip cache'le.
        //    Bu, biyometrik anahtarda TEK SEFERLİK prompt çıkarır; sonraki kayıtlar cache'ten döner. (Çoğu
        //    eski kurulumda decryptWithUserKey zaten cache'i daha erken doldurur → bu yola düşülmez.)
        if let existing = try? loadPrivateKey(tag: tag, context: nil),
           let pub = SecKeyCopyPublicKey(existing),
           let spki = RSAKey.spkiBase64(of: pub) {
            cachePublicKey(spki, tag: tag)
            return spki
        }
        // 3) Anahtar yok → üret, public'i cache'le (üretim anında prompt yok).
        let priv = try generateKey(tag: tag, biometric: biometric)
        guard let pub = SecKeyCopyPublicKey(priv), let spki = RSAKey.spkiBase64(of: pub) else {
            throw KeychainKeyStoreError.publicKeyExtractionFailed
        }
        cachePublicKey(spki, tag: tag)
        Log.info("KeychainKeyStore: \(biometric ? "user" : "history") key üretildi", category: .crypto)
        return spki
    }

    // MARK: - Public key cache (biyometriksiz generic-password)

    private static func account(for tag: Data) -> String { String(decoding: tag, as: UTF8.self) }

    private static func cachedPublicKey(tag: Data) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: pubCacheService,
            kSecAttrAccount as String: account(for: tag),
            kSecReturnData as String:  true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cachePublicKey(_ spki: String, tag: Data) {
        deleteCachedPublicKey(tag: tag) // idempotent (duplicate item hatası önle)
        let attrs: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  pubCacheService,
            kSecAttrAccount as String:  account(for: tag),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String:    Data(spki.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            Log.warning("KeychainKeyStore: public key cache yazılamadı (OSStatus \(status))", category: .crypto)
        }
    }

    private static func deleteCachedPublicKey(tag: Data) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: pubCacheService,
            kSecAttrAccount as String: account(for: tag),
        ]
        SecItemDelete(query as CFDictionary)
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
                    // Hata KODU korunur, `localizedDescription` DEĞİL: metin cihaz diline göre değişip
                    // Sentry gruplamasını böler ve iptali gerçek arızadan ayırmayı imkânsız kılar.
                    cont.resume(throwing: KeychainKeyStoreError.fromAuthError(error))
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
    /// Kullanıcı ya da sistem prompt'u kapattı — arıza DEĞİL. Sentry'ye event gitmez (bkz. `Log.sentryLevel`).
    case authCancelled(code: Int)
    /// Gerçek local-auth hatası (lockout, donanım, kayıt yok). Kod LAError.Code ham değeridir.
    case authFailed(code: Int)
    case fetchFailed(OSStatus)

    /// `evaluatePolicy` hatasını sınıfına göre uygun case'e çevirir.
    static func fromAuthError(_ error: Error?) -> KeychainKeyStoreError {
        let code = BiometricErrorClass.laCode(of: error)
        return BiometricErrorClass.classify(code: code) == .cancelled
            ? .authCancelled(code: code)
            : .authFailed(code: code)
    }

    var description: String {
        switch self {
        case .generationFailed(let m):     return "generationFailed(\(m))"
        case .publicKeyExtractionFailed:   return "publicKeyExtractionFailed"
        case .keyNotFound:                 return "keyNotFound"
        case .authCancelled(let c):        return "authCancelled(LAError \(c))"
        case .authFailed(let c):           return "authFailed(LAError \(c))"
        case .fetchFailed(let s):          return "fetchFailed(OSStatus \(s))"
        }
    }

    var localizedDescription: String { description }
}

/// Kullanıcıya gösterilecek metin. Akışların `fail(...)` çağrıları `(error as? LocalizedError)?.errorDescription`
/// okuduğu için biyometrik durumlar burada tek yerden yerelleştirilir — sistemin teknik metni ekrana ÇIKMAZ.
extension KeychainKeyStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .authCancelled:        return L.t("biometric_cancelled_message")
        case .authFailed(let code): return L.t(BiometricErrorClass.userMessageKey(code: code))
        default:                    return nil   // diğerleri akışın kendi genel mesajına düşer
        }
    }
}
