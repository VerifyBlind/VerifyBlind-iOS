import Foundation
import CryptoKit

/// `.vfbackup` kripto çekirdeği — tüm-dosya AES-256-GCM, anahtar paroladan yerel PBKDF2 ile.
/// Android `backup/BackupCrypto.kt` BİREBİR portu. Kanonik sözleşme:
/// `docs/superpowers/specs/2026-07-23-manual-backup-restore-design.md`.
///
/// İki platform BİT-BİT aynı sonucu üretmek zorundadır → değerler RFC 7914 PBKDF2-HMAC-SHA256
/// golden vektörleriyle kilitlidir (`BackupCrypto.selfTestGoldenVectors()`).
///
/// **Neden elle PBKDF2 (CommonCrypto `CCKeyDerivationPBKDF` değil):** parolanın NFC+UTF-8 bayt
/// dönüşümünü tümüyle biz kontrol edelim → Android (Conscrypt) ile bit-bit aynı. `HMAC<SHA256>`
/// üzerine kuruludur; salt sır değildir; kodda sabit/pepper YOKTUR.
enum BackupCrypto {

    private static let hLen = 32          // SHA-256 çıktı uzunluğu
    private static let gcmIvBytes = 12
    private static let gcmTagBytes = 16

    /// PBKDF2-HMAC-SHA256. Parola önce Unicode NFC'ye normalize edilir, sonra UTF-8'e çevrilir
    /// (çapraz-platform tuzağı). `dkLenBytes` varsayılan 32 (AES-256).
    static func deriveKey(password: String, salt: Data, iterations: Int, dkLenBytes: Int = 32) -> Data {
        // NFC normalize = precomposedStringWithCanonicalMapping.
        let pwBytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
        let key = SymmetricKey(data: pwBytes)

        let blocks = (dkLenBytes + hLen - 1) / hLen
        var out = Data()

        for i in 1...blocks {
            // U1 = PRF(password, salt || INT_32_BE(i))
            var msg = salt
            msg.append(UInt8(truncatingIfNeeded: i >> 24))
            msg.append(UInt8(truncatingIfNeeded: i >> 16))
            msg.append(UInt8(truncatingIfNeeded: i >> 8))
            msg.append(UInt8(truncatingIfNeeded: i))

            var u = Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
            var t = [UInt8](u)
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    let ub = [UInt8](u)
                    for k in 0..<hLen { t[k] ^= ub[k] }
                }
            }
            out.append(contentsOf: t)
        }
        return out.prefix(dkLenBytes)
    }

    /// AES-256-GCM şifreler. Rastgele 12 baytlık IV. Dönüş: (iv, ciphertext‖16-bayt-tag) — Android
    /// `Cipher.doFinal` çıktısıyla aynı düzen (tag ciphertext'e eklenir; IV ayrı saklanır).
    static func encrypt(plaintext: Data, key: Data) throws -> (iv: Data, ciphertext: Data) {
        let symKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce() // rastgele 12 bayt
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        return (Data(nonce), sealed.ciphertext + sealed.tag)
    }

    /// AES-256-GCM çözer. `ciphertextWithTag` = ciphertext‖tag. Yanlış anahtar / kurcalanmış veri
    /// throw eder (çağıran "yanlış parola / bozuk dosya" olarak yorumlar).
    static func decrypt(iv: Data, ciphertextWithTag: Data, key: Data) throws -> Data {
        guard ciphertextWithTag.count >= gcmTagBytes else {
            throw CryptoKitError.incorrectParameterSize
        }
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: iv)
        let ct = ciphertextWithTag.prefix(ciphertextWithTag.count - gcmTagBytes)
        let tag = ciphertextWithTag.suffix(gcmTagBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ct), tag: Data(tag))
        return try AES.GCM.open(box, using: symKey)
    }

    // MARK: - Golden vector self-test (Android BackupCryptoTest paritesi)

    /// RFC 7914 §11 PBKDF2-HMAC-SHA256 vektörleriyle çapraz-platform sözleşmeyi doğrular.
    /// Android `BackupCryptoTest` ile AYNI beklenen değerler. Hata mesajı döner, başarıda nil.
    static func selfTestGoldenVectors() -> String? {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

        let v1 = deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1, dkLenBytes: 64)
        let e1 = "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc" +
                 "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
        if hex(v1) != e1 { return "PBKDF2 vektör(c=1) uyuşmadı: \(hex(v1))" }

        let v2 = deriveKey(password: "Password", salt: Data("NaCl".utf8), iterations: 80000, dkLenBytes: 64)
        let e2 = "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56" +
                 "a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"
        if hex(v2) != e2 { return "PBKDF2 vektör(c=80000) uyuşmadı" }

        // AES-GCM round-trip + yanlış anahtar reddi.
        do {
            let key = deriveKey(password: "hunter2-strong", salt: Data("salt".utf8), iterations: 1000)
            let pt = Data("{\"records\":[]}".utf8)
            let (iv, ct) = try encrypt(plaintext: pt, key: key)
            let back = try decrypt(iv: iv, ciphertextWithTag: ct, key: key)
            if back != pt { return "AES-GCM round-trip uyuşmadı" }
            let wrong = deriveKey(password: "nope", salt: Data("salt".utf8), iterations: 1000)
            if (try? decrypt(iv: iv, ciphertextWithTag: ct, key: wrong)) != nil {
                return "AES-GCM yanlış anahtarı reddetmedi"
            }
        } catch {
            return "AES-GCM self-test istisnası: \(error)"
        }
        return nil
    }
}
