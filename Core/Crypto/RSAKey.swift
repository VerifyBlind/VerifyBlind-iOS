import Foundation
import Security
import CryptoKit

/// X.509 SubjectPublicKeyInfo (SPKI) ↔ iOS `SecKey` köprüsü.
///
/// iOS `SecKeyCreateWithData`, RSA public key için **PKCS#1** (ham RSAPublicKey) DER bekler;
/// Enclave ise anahtarı base64 **SPKI** olarak gönderir. Bu yardımcı, SPKI'nin ASN.1
/// AlgorithmIdentifier başlığını soyup içteki PKCS#1'i çıkarır. Cert pinning için ise
/// PKCS#1'i tekrar SPKI'ye sarıp SHA-256 hesaplar (pin formatı: `sha256/<base64(SPKI-SHA256)>`).
///
/// DER uzunlukları kısa/uzun formda ayrıştırılır; RSA-2048'e özgü sabit prefix'e
/// güvenilmez (modulus/exponent uzunluğu değişebilir).
enum RSAKey {

    /// rsaEncryption AlgorithmIdentifier (sabit): SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
    private static let rsaAlgIdentifier: [UInt8] = [
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
    ]

    // MARK: - SPKI → SecKey

    /// base64 SPKI → RSA public `SecKey`. Hata olursa nil döner (loglar).
    static func publicKey(fromSPKIBase64 b64: String) -> SecKey? {
        let trimmed = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spki = Data(base64Encoded: trimmed)
            ?? Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            Log.error("RSAKey: SPKI base64 decode failed", category: .crypto)
            return nil
        }
        return publicKey(fromSPKI: spki)
    }

    static func publicKey(fromSPKI spki: Data) -> SecKey? {
        guard let pkcs1 = pkcs1(fromSPKI: spki) else {
            Log.error("RSAKey: SPKI→PKCS#1 ayrıştırma başarısız", category: .crypto)
            return nil
        }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            Log.error("RSAKey: SecKeyCreateWithData başarısız: \(Self.cfErr(error))", category: .crypto)
            return nil
        }
        return key
    }

    // MARK: - SecKey → SPKI SHA-256 (cert pinning)

    /// RSA public `SecKey` → SPKI DER'in SHA-256'sı. Cert pinning pin'iyle karşılaştırmak için.
    static func spkiSHA256(of key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        // RSA public key için external representation = PKCS#1 RSAPublicKey DER.
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            Log.error("RSAKey: SecKeyCopyExternalRepresentation başarısız: \(Self.cfErr(error))", category: .crypto)
            return nil
        }
        let spki = spkiDER(fromPKCS1: pkcs1)
        return Data(SHA256.hash(data: spki))
    }

    // MARK: - DER ayrıştırma

    /// SPKI DER → içteki PKCS#1 RSAPublicKey DER.
    private static func pkcs1(fromSPKI spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        // Dış SEQUENCE (SPKI)
        var idx = 0
        guard let spkiSeq = readTLV(bytes, &idx, expect: 0x30) else { return nil }
        let innerEnd = spkiSeq.valueStart + spkiSeq.valueLen
        // AlgorithmIdentifier SEQUENCE — atla
        var inner = spkiSeq.valueStart
        guard let alg = readTLV(bytes, &inner, expect: 0x30) else { return nil }
        inner = alg.valueStart + alg.valueLen
        guard inner < innerEnd else { return nil }
        // BIT STRING
        guard let bit = readTLV(bytes, &inner, expect: 0x03), bit.valueLen >= 1 else { return nil }
        // İlk byte = unused-bits sayacı (RSA için 0x00) — atla.
        let start = bit.valueStart + 1
        let len = bit.valueLen - 1
        guard start + len <= bytes.count else { return nil }
        return Data(bytes[start ..< start + len])
    }

    /// TLV oku; `tag` eşleşmeli. idx, length byte'larından sonra (value başına) bırakılır.
    private static func readTLV(_ bytes: [UInt8], _ idx: inout Int, expect tag: UInt8) -> (valueStart: Int, valueLen: Int)? {
        guard idx < bytes.count, bytes[idx] == tag else { return nil }
        idx += 1
        guard idx < bytes.count else { return nil }
        var length = Int(bytes[idx]); idx += 1
        if length & 0x80 != 0 {
            let numBytes = length & 0x7f
            guard numBytes > 0, numBytes <= 4, idx + numBytes <= bytes.count else { return nil }
            length = 0
            for _ in 0..<numBytes {
                length = (length << 8) | Int(bytes[idx])
                idx += 1
            }
        }
        guard idx + length <= bytes.count else { return nil }
        return (idx, length)
    }

    /// PKCS#1 RSAPublicKey DER → tam SPKI DER (algoritma başlığı + BIT STRING ile sar).
    private static func spkiDER(fromPKCS1 pkcs1: Data) -> Data {
        let bitString = derTLV(tag: 0x03, value: [0x00] + [UInt8](pkcs1))
        let body = rsaAlgIdentifier + bitString
        return Data(derTLV(tag: 0x30, value: body))
    }

    private static func derTLV(tag: UInt8, value: [UInt8]) -> [UInt8] {
        [tag] + derLength(value.count) + value
    }

    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var len = n
        var out: [UInt8] = []
        while len > 0 {
            out.insert(UInt8(len & 0xff), at: 0)
            len >>= 8
        }
        return [UInt8(0x80 | out.count)] + out
    }

    private static func cfErr(_ e: Unmanaged<CFError>?) -> String {
        guard let err = e?.takeRetainedValue() else { return "unknown" }
        return (CFErrorCopyDescription(err) as String?) ?? "unknown"
    }
}
