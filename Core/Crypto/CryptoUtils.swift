import Foundation
import Security
import CryptoKit

enum CryptoError: Error, CustomStringConvertible {
    case invalidBase64
    case invalidPublicKey
    case algorithmUnsupported
    case encryptionFailed(String)
    case decryptionFailed(String)

    var description: String {
        switch self {
        case .invalidBase64:            return "invalidBase64"
        case .invalidPublicKey:         return "invalidPublicKey"
        case .algorithmUnsupported:     return "algorithmUnsupported"
        case .encryptionFailed(let m):  return "encryptionFailed(\(m))"
        case .decryptionFailed(let m):  return "decryptionFailed(\(m))"
        }
    }
}

/// Android `crypto/CryptoUtils.kt`'nin durumsuz (Keychain'e bağlı OLMAYAN) bölümünün portu.
///
/// Sunucu (`VerifyBlind.Core/CryptoUtils.cs`) ve Android ile **byte-uyumlu** olmak zorundadır:
/// - RSA/OAEP-SHA256 (Enclave), RSA/OAEP-SHA1 (Keychain/Keystore tarafı)
/// - AES-256-GCM, 12-byte nonce, 16-byte tag; blob = `nonce‖ciphertext‖tag`
/// - SHA-256, RSA-PSS/SHA-256 doğrulama
///
/// Keychain'e bağlı parçalar (biyometrik RSA keypair üretimi, ticket saklama/çözme) Aşama 4'tedir.
enum CryptoUtils {

    // MARK: - RSA encrypt (software, public key)

    /// OAEP-SHA256 / MGF1-SHA256 — Enclave public key (.NET `RsaEncrypt`) için. base64 out.
    static func rsaEncrypt(_ plaintext: String, publicKeyBase64: String) throws -> String {
        try rsaEncrypt(plaintext, publicKeyBase64: publicKeyBase64, algorithm: .rsaEncryptionOAEPSHA256)
    }

    /// OAEP-SHA1 / MGF1-SHA1 — Keychain/Keystore-backed anahtarlar (.NET `RsaEncryptOaepSha1`) için.
    /// Aşama 1'de yalnızca encrypt yönü; karşı taraf (decrypt) Aşama 4 Keychain anahtarı.
    static func rsaEncryptForKeystore(_ plaintext: String, publicKeyBase64: String) throws -> String {
        try rsaEncrypt(plaintext, publicKeyBase64: publicKeyBase64, algorithm: .rsaEncryptionOAEPSHA1)
    }

    private static func rsaEncrypt(_ plaintext: String, publicKeyBase64: String, algorithm: SecKeyAlgorithm) throws -> String {
        guard let key = RSAKey.publicKey(fromSPKIBase64: publicKeyBase64) else {
            throw CryptoError.invalidPublicKey
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
            throw CryptoError.algorithmUnsupported
        }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key, algorithm, Data(plaintext.utf8) as CFData, &error) as Data? else {
            let msg = Self.cfErr(error)
            Log.error("CryptoUtils.rsaEncrypt başarısız: \(msg)", category: .crypto)
            throw CryptoError.encryptionFailed(msg)
        }
        return cipher.base64EncodedString()
    }

    // MARK: - RSA decrypt (Keychain private key — Aşama 4 ticket/history çözme)

    /// Verilen `SecKey` (Keychain'de yaşayan private key) ile RSA-OAEP decrypt.
    /// User/History anahtarları OAEP-SHA1 ile sarılır (Android `keystoreOaepSpec` paritesi) →
    /// varsayılan algoritma `.rsaEncryptionOAEPSHA1`. Biyometrik kapılı anahtarlarda `SecKey`
    /// LAContext ile çekilmiş olmalı (prompt erişimde tetiklenir). `KeychainKeyStore` kullanır.
    static func rsaDecrypt(_ cipherBase64: String, privateKey: SecKey,
                           algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA1) throws -> String {
        guard let cipher = decodeBase64(cipherBase64) else { throw CryptoError.invalidBase64 }
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw CryptoError.algorithmUnsupported
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(privateKey, algorithm, cipher as CFData, &error) as Data? else {
            let msg = Self.cfErr(error)
            Log.error("CryptoUtils.rsaDecrypt başarısız: \(msg)", category: .crypto)
            throw CryptoError.decryptionFailed(msg)
        }
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: - AES-GCM (rastgele key, IV blob içinde gömülü)

    /// Android `aesEncrypt`: rastgele 256-bit key. blob = nonce(12)‖ciphertext‖tag(16).
    /// Dönüş: (blob base64, key base64). Android IV'yi ayrıca döndürüyordu ama blob'a gömülü olduğu için gerekmez.
    static func aesEncrypt(_ plaintext: String) throws -> (blob: String, key: String) {
        let key = SymmetricKey(size: .bits256)
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            guard let combined = sealed.combined else {
                throw CryptoError.encryptionFailed("AES.GCM.combined nil")
            }
            let keyData = key.withUnsafeBytes { Data($0) }
            return (combined.base64EncodedString(), keyData.base64EncodedString())
        } catch let e as CryptoError {
            throw e
        } catch {
            Log.error("CryptoUtils.aesEncrypt başarısız", error: error, category: .crypto)
            throw CryptoError.encryptionFailed("\(error)")
        }
    }

    /// Android `aesDecrypt`: blob = nonce(12)‖ciphertext‖tag(16), key base64.
    static func aesDecrypt(blobBase64: String, keyBase64: String) throws -> String {
        guard let blob = decodeBase64(blobBase64), let keyData = decodeBase64(keyBase64) else {
            throw CryptoError.invalidBase64
        }
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            Log.error("CryptoUtils.aesDecrypt başarısız", error: error, category: .crypto)
            throw CryptoError.decryptionFailed("\(error)")
        }
    }

    // MARK: - AES-GCM (personId-türevli key — cloud sync, Aşama 5'te kullanılır)

    static func deriveKeyFromPersonId(_ personId: String) -> SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data(personId.utf8))))
    }

    /// Android `aesGcmEncrypt`: ciphertext alanı = ciphertext‖tag (Java `doFinal` davranışı), iv ayrı alan.
    static func aesGcmEncrypt(_ data: String, personId: String) throws -> (ciphertext: String, iv: String) {
        do {
            let sealed = try AES.GCM.seal(Data(data.utf8), using: deriveKeyFromPersonId(personId))
            var ctWithTag = Data(sealed.ciphertext)
            ctWithTag.append(sealed.tag)
            return (ctWithTag.base64EncodedString(), Data(sealed.nonce).base64EncodedString())
        } catch {
            Log.error("CryptoUtils.aesGcmEncrypt başarısız", error: error, category: .crypto)
            throw CryptoError.encryptionFailed("\(error)")
        }
    }

    /// Android `aesGcmDecrypt`: ciphertext = ct‖tag (son 16 byte = tag), iv ayrı, key personId'den türetilir.
    static func aesGcmDecrypt(ciphertextBase64: String, ivBase64: String, personId: String) throws -> String {
        guard let ctWithTag = decodeBase64(ciphertextBase64), let ivData = decodeBase64(ivBase64) else {
            throw CryptoError.invalidBase64
        }
        guard ctWithTag.count >= 16 else { throw CryptoError.decryptionFailed("ciphertext < 16 byte") }
        let tag = ctWithTag.suffix(16)
        let ct = ctWithTag.prefix(ctWithTag.count - 16)
        do {
            let nonce = try AES.GCM.Nonce(data: ivData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            let plain = try AES.GCM.open(box, using: deriveKeyFromPersonId(personId))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            Log.error("CryptoUtils.aesGcmDecrypt başarısız", error: error, category: .crypto)
            throw CryptoError.decryptionFailed("\(error)")
        }
    }

    // MARK: - AES-GCM (HAM anahtar — DEK/KEK sarma; Android `aesGcmEncryptRaw`/`aesGcmDecryptRaw`)
    //
    // Yukarıdaki personId'li varyantlar anahtarı SHA256(personId) ile TÜRETİR ve v1 bulut yedek
    // formatı için AYNEN korunur. Aşağıdakiler ham 32 baytlık anahtar alır.
    //
    // Neden: yedek artık rastgele bir DEK ile şifrelenir; DEK ise personId'den türeyen KEK ile
    // sarılıp dosyadaki `wraps[]` içinde tutulur. Aynı DEK birden çok KEK ile sarılabildiği için
    // kimlik tabanı değişince (TCKN → PIN) yalnız yeni bir wrap eklenir, geçmiş yeniden
    // şifrelenmez. DEK rastgeledir → türetilemez → ham anahtar alan varyant şart.

    /// Android `kekFromPersonId` ile BİREBİR: SHA256(personId) ham baytları.
    /// `deriveKeyFromPersonId` ile aynı baytı verir — v1→v2 geçişinde mevcut personId'ler
    /// wrap'leri açabilsin diye kasıtlı.
    static func kekFromPersonId(_ personId: String) -> Data {
        sha256Bytes(personId)
    }

    /// Android `generateDek`: yeni rastgele DEK (32 bayt). Kimlikten bağımsız.
    static func generateDek() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Android `aesGcmEncryptRaw`: ciphertext alanı = ciphertext‖tag, iv ayrı alan.
    static func aesGcmEncryptRaw(_ data: String, key: Data) throws -> (ciphertext: String, iv: String) {
        do {
            let sealed = try AES.GCM.seal(Data(data.utf8), using: SymmetricKey(data: key))
            var ctWithTag = Data(sealed.ciphertext)
            ctWithTag.append(sealed.tag)
            return (ctWithTag.base64EncodedString(), Data(sealed.nonce).base64EncodedString())
        } catch {
            Log.error("CryptoUtils.aesGcmEncryptRaw başarısız", error: error, category: .crypto)
            throw CryptoError.encryptionFailed("\(error)")
        }
    }

    /// Android `aesGcmDecryptRaw`: ciphertext = ct‖tag (son 16 byte = tag), iv ayrı, ham anahtar.
    static func aesGcmDecryptRaw(ciphertextBase64: String, ivBase64: String, key: Data) throws -> String {
        guard let ctWithTag = decodeBase64(ciphertextBase64), let ivData = decodeBase64(ivBase64) else {
            throw CryptoError.invalidBase64
        }
        guard ctWithTag.count >= 16 else { throw CryptoError.decryptionFailed("ciphertext < 16 byte") }
        let tag = ctWithTag.suffix(16)
        let ct = ctWithTag.prefix(ctWithTag.count - 16)
        do {
            let nonce = try AES.GCM.Nonce(data: ivData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            // Yanlış KEK (GCM tag uyumsuz) normal bir durum: çağıran tüm personId'leri dener.
            throw CryptoError.decryptionFailed("\(error)")
        }
    }

    // MARK: - Hashing

    /// Android `sha256`: lowercase hex (64 karakter).
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Android `sha256Bytes(String)`: ham 32 byte.
    static func sha256Bytes(_ input: String) -> Data {
        Data(SHA256.hash(data: Data(input.utf8)))
    }

    /// Android `sha256Bytes(ByteArray)`: ham 32 byte.
    static func sha256Bytes(_ input: Data) -> Data {
        Data(SHA256.hash(data: input))
    }

    // MARK: - RSA-PSS doğrulama (sunucu imzaları)

    /// Sunucu PSS imzası doğrulama (.NET `CryptoUtils.SignData` — PSS, SHA-256, MGF1-SHA256 ile uyumlu).
    /// Hata/uyumsuzlukta false. (İleride nonce/PCR0 imza doğrulamasının temeli.)
    static func verifyPssSignature(data: String, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let key = RSAKey.publicKey(fromSPKIBase64: publicKeyBase64),
              let sig = decodeBase64(signatureBase64) else {
            return false
        }
        let algorithm: SecKeyAlgorithm = .rsaSignatureMessagePSSSHA256
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(key, algorithm, Data(data.utf8) as CFData, sig as CFData, &error)
        if !ok {
            Log.debug("CryptoUtils.verifyPssSignature false: \(Self.cfErr(error))", category: .crypto)
        }
        return ok
    }

    // MARK: - RSA-PSS imzalama (holder-of-key, Y-4)

    /// Holder-of-key kanıtı: user key (Keychain, biyometrik-kapılı) ile RSA-PSS/SHA-256 imza.
    /// `.rsaSignatureMessagePSSSHA256` → MGF1-SHA256, salt=digest(32); .NET `RSASignaturePadding.Pss`
    /// (enclave `CryptoUtils.VerifySignature`) ve Android `SHA256withRSA/PSS` ile byte-uyumlu.
    /// `privateKey` çağrıdan ÖNCE doğrulanmış bir LAContext ile çekilmiş olmalı (ek prompt çıkmaz).
    static func rsaSignPSS(_ message: String, privateKey: SecKey) throws -> String {
        let algorithm: SecKeyAlgorithm = .rsaSignatureMessagePSSSHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw CryptoError.algorithmUnsupported
        }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, algorithm, Data(message.utf8) as CFData, &error) as Data? else {
            let msg = Self.cfErr(error)
            Log.error("CryptoUtils.rsaSignPSS başarısız: \(msg)", category: .crypto)
            throw CryptoError.encryptionFailed(msg)
        }
        return sig.base64EncodedString()
    }

    // MARK: - Base64 yardımcı

    /// Android `Base64.DEFAULT` toleransı: whitespace/newline trim + bilinmeyen karakter atla.
    static func decodeBase64(_ s: String) -> Data? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Data(base64Encoded: trimmed) { return d }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }

    private static func cfErr(_ e: Unmanaged<CFError>?) -> String {
        guard let err = e?.takeRetainedValue() else { return "unknown" }
        return (CFErrorCopyDescription(err) as String?) ?? "unknown"
    }
}
