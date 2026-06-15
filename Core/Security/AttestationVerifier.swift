import Foundation
import Security
import SwiftCBOR
import CommonCrypto

/// AWS Nitro Enclave attestation doğrulayıcısı — Android `AttestationVerifier.kt` Swift portu.
///
/// Üç aşamalı doğrulama:
///   1. AWS Root CA sertifika zinciri   → belge gerçekten Nitro donanımından mı?
///   2. PCR0 developer RSA imzası       → çalışan kod, onaylı sürüm mü?
///   3. user_data'dan enclave public key → relay yerine donanım belgesinden anahtar al.
///
/// `HandshakeService` bu doğrulamayı geçene kadar `enclavePubKey`'i kullanmaz (ZKP garantisi).
enum AttestationVerifier {

    struct VerificationResult {
        let isValid: Bool
        let failReason: String?
        let pcr0: String?
        let enclavePubKey: String?
        let isMockDocument: Bool

        static func fail(_ reason: String) -> VerificationResult {
            VerificationResult(isValid: false, failReason: reason, pcr0: nil, enclavePubKey: nil, isMockDocument: false)
        }
    }

    // AWS Nitro Enclaves Root CA G1 — PEM'in base64 gövdesi (başlık/bitiş satırları hariç).
    // Referans: https://docs.aws.amazon.com/enclaves/latest/user/verify-root.html
    private static let awsNitroRootG1Der = """
MIICETCCAZagAwIBAgIRAPkxdWgbkK/hHUbMtOTn+FYwCgYIKoZIzj0EAwMwSTEL
MAkGA1UEBhMCVVMxDzANBgNVBAoMBkFtYXpvbjEMMAoGA1UECwwDQVdTMRswGQYD
VQQDDBJhd3Mubml0cm8tZW5jbGF2ZXMwHhcNMTkxMDI4MTMyODA1WhcNNDkxMDI4
MTQyODA1WjBJMQswCQYDVQQGEwJVUzEPMA0GA1UECgwGQW1hem9uMQwwCgYDVQQL
DANBV1MxGzAZBgNVBAMMEmF3cy5uaXRyby1lbmNsYXZlczB2MBAGByqGSM49AgEG
BSuBBAAiA2IABPwCVOumCMHzaHDimtqQvkY4MpJzbolL//Zy2YlES1BR5TSksfbb
48C8WBoyt7F2Bw7eEtaaP+ohG2bnUs990d0JX28TcPQXCEPZ3BABIeTPYwEoCWZE
h8l5YoQwTcU/9KNCMEAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUkCW1DdkF
R+eWw5b6cp3PmanfS5YwDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMDA2kAMGYC
MQCjfy+Rocm9Xue4YnwWmNJVA44fA0P5W2OpYow9OYCVRaEevL8uO1XYru5xtMPW
rfMCMQCi85sWBbJwKKXdS6BptQFuZbT73o/gBh1qUxl/nNr12UO8Yfwr6wPLb+6N
IwLz3/Y=
"""

    // Bölgesel fallback parmak izleri (Android `TRUSTED_AWS_ROOT_FINGERPRINTS` paritesi).
    private static let trustedFingerprints: Set<String> = [
        "8cf60e2b2efca96c6a9e71e851d00c1b6991cc09eadbe64a6a1d1b1eb9faff7c",
        "544b3038ae723a3c1e2e0d50af1c9bb82078f37d3662a28ce3ef93e67d27459f"
    ]

    // MARK: - Entry point

    static func verify(attestationBase64: String, pcr0Signature: String?, isDevelopment: Bool) -> VerificationResult {
        guard !attestationBase64.isEmpty else {
            return .fail("Attestation document eksik")
        }
        guard let docBytes = Data(base64Encoded: attestationBase64, options: .ignoreUnknownCharacters) else {
            return .fail("Attestation base64 decode edilemiyor")
        }
        guard let top = try? CBOR.decode([UInt8](docBytes)) else {
            return .fail("Attestation CBOR parse hatası")
        }
        // COSE_Sign1: [protected, unprotected, payload(byteString), signature]
        guard case let .array(arr) = top, arr.count >= 4,
              case let .byteString(payloadBytes) = arr[2],
              let payloadCbor = try? CBOR.decode(payloadBytes),
              case let .map(payloadMap) = payloadCbor else {
            return .fail("Geçersiz COSE_Sign1 yapısı")
        }

        let result = verifyPayload(payloadMap: payloadMap, pcr0Signature: pcr0Signature, isDevelopment: isDevelopment)
        guard result.isValid else { return result }

        // K-1: COSE_Sign1 imza doğrulaması (payload ↔ donanım bağı). Mevcut 3 kontrol (zincir/PCR0/
        // pubkey), saldırganın gerçek bir belgenin user_data'sını kendi anahtarıyla değiştirmesini
        // ENGELLEMEZ; bu imza payload'ın (user_data dahil) leaf'in private key'iyle imzalandığını
        // kanıtlar. Dev/mock belge (PCR0 sıfır) gerçek donanım imzası taşımaz → atlanır.
        if result.isMockDocument { return result }
        guard case let .byteString(protectedBytes) = arr[0],
              case let .byteString(signatureBytes) = arr[3] else {
            return .fail("COSE protected header / signature okunamadı")
        }
        let (coseOK, coseErr) = verifyCoseSignature(protectedHeader: protectedBytes, payload: payloadBytes,
                                                    signature: signatureBytes, payloadMap: payloadMap)
        guard coseOK else { return .fail("COSE imza doğrulaması BAŞARISIZ: \(coseErr)") }
        Log.info("[Tasdik] ✅ COSE_Sign1 imzası leaf sertifikayla doğrulandı", category: .flow)
        return result
    }

    // MARK: - Ana doğrulama

    private static func verifyPayload(payloadMap: [CBOR: CBOR], pcr0Signature: String?, isDevelopment: Bool) -> VerificationResult {
        // Kontrol 1: Sertifika zinciri
        let (chainOK, chainErr) = verifyCertChain(payloadMap: payloadMap)
        guard chainOK else {
            return .fail("AWS CA zinciri BAŞARISIZ: \(chainErr)")
        }
        Log.info("[Tasdik] ✅ 1/3: AWS Root CA doğrulandı", category: .flow)

        let pcr0 = extractPcr0(payloadMap: payloadMap)
        Log.info("[Tasdik] PCR0: \(pcr0.prefix(16))…", category: .flow)

        // Tümü-sıfır PCR0 → debug enclave
        if pcr0 != "UNKNOWN" && pcr0.allSatisfy({ $0 == "0" }) {
            if isDevelopment {
                Log.warning("[Tasdik] ⚠️ Debug enclave (PCR0 sıfır), development modda kabul", category: .flow)
                let pub = extractEnclavePubKey(payloadMap: payloadMap)
                return VerificationResult(isValid: true, failReason: nil, pcr0: pcr0, enclavePubKey: pub, isMockDocument: true)
            }
            return .fail("Enclave debug modda (PCR0 sıfır) — prod'da kabul edilmez")
        }

        // Kontrol 2: PCR0 developer imzası (Android `verifyPcr0Authorization` portu)
        guard let sig = pcr0Signature, !sig.isEmpty else {
            return .fail("Yetkisiz Enclave: PCR0 imzası sağlanmadı")
        }
        let (authOK, authErr) = verifyPcr0Signature(pcr0: pcr0, signatureBase64: sig)
        guard authOK else {
            return .fail("PCR0 imza doğrulaması BAŞARISIZ: \(authErr)")
        }
        Log.info("[Tasdik] ✅ 2/3: PCR0 developer imzası geçerli", category: .flow)

        // Kontrol 3: Enclave public key (user_data'dan — relay iddiasından DEĞİL)
        guard let enclavePubKey = extractEnclavePubKey(payloadMap: payloadMap), !enclavePubKey.isEmpty else {
            return .fail("user_data'dan enclave public key çıkarılamadı")
        }
        Log.info("[Tasdik] ✅ 3/3: Enclave public key donanım zarfından alındı", category: .flow)

        return VerificationResult(isValid: true, failReason: nil, pcr0: pcr0, enclavePubKey: enclavePubKey, isMockDocument: false)
    }

    // MARK: - Kontrol 1: Sertifika zinciri

    private static func verifyCertChain(payloadMap: [CBOR: CBOR]) -> (Bool, String) {
        guard let awsRoot = loadAwsRootCert() else {
            return (false, "AWS Root CA yüklenemedi")
        }
        guard case let .byteString(leafBytes)? = payloadMap[.utf8String("certificate")],
              let leafCert = SecCertificateCreateWithData(nil, Data(leafBytes) as CFData) else {
            return (false, "Leaf certificate parse hatası")
        }

        var certs: [SecCertificate] = [leafCert]
        if case let .array(cabundle)? = payloadMap[.utf8String("cabundle")] {
            for item in cabundle {
                if case let .byteString(b) = item,
                   let c = SecCertificateCreateWithData(nil, Data(b) as CFData) {
                    certs.append(c)
                }
            }
        }

        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return (false, "SecTrust oluşturulamadı")
        }

        // Yalnız AWS Root G1 + tanınan parmak izleri anchor olarak kullan
        var anchors: [SecCertificate] = [awsRoot]
        for cert in certs {
            let fp = sha256Hex(SecCertificateCopyData(cert) as Data)
            if trustedFingerprints.contains(fp) { anchors.append(cert) }
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var cfErr: CFError?
        if SecTrustEvaluateWithError(trust, &cfErr) { return (true, "OK") }
        let desc = cfErr.map { CFErrorCopyDescription($0) as String } ?? "Doğrulama hatası"
        return (false, desc)
    }

    private static func loadAwsRootCert() -> SecCertificate? {
        let stripped = awsNitroRootG1Der
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: stripped) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    // MARK: - Kontrol 2: PCR0 developer RSA imzası

    private static func verifyPcr0Signature(pcr0: String, signatureBase64: String) -> (Bool, String) {
        guard let sigData = Data(base64Encoded: signatureBase64) else {
            return (false, "İmza base64 decode hatası")
        }
        let devKeyBase64 = Config.enclaveDeveloperPublicKey
        guard !devKeyBase64.isEmpty, let blobData = Data(base64Encoded: devKeyBase64) else {
            return (false, "Developer public key yapılandırılmamış")
        }
        guard let secKey = parseRsaCspBlobToSecKey([UInt8](blobData)) else {
            return (false, "RSA CSP blob parse hatası")
        }
        let algo = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(secKey, .verify, algo) else {
            return (false, "Algoritma desteklenmiyor")
        }
        var verifyErr: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(secKey, algo, Data(pcr0.utf8) as CFData, sigData as CFData, &verifyErr)
        if valid { return (true, "OK") }
        let desc = verifyErr?.takeRetainedValue().localizedDescription ?? "İmza uyuşmazlığı"
        return (false, desc)
    }

    /// Windows RSA CSP Public Key Blob → SecKey (Android `parseRsaCspBlob` portu).
    /// Format: BLOBHEADER(8B) | RSAPUBKEY: magic(4) bitLen(4) pubExp(4) | modulus(bitLen/8B)
    private static func parseRsaCspBlobToSecKey(_ blob: [UInt8]) -> SecKey? {
        guard blob.count > 20, blob[0] == 0x06 else { return nil }  // PUBLICKEYBLOB type
        let magic = UInt32(blob[8]) | (UInt32(blob[9]) << 8) | (UInt32(blob[10]) << 16) | (UInt32(blob[11]) << 24)
        guard magic == 0x31415352 else { return nil }  // 'RSA1'
        let bitLen = Int(UInt32(blob[12]) | (UInt32(blob[13]) << 8) | (UInt32(blob[14]) << 16) | (UInt32(blob[15]) << 24))
        let expLE  = UInt32(blob[16]) | (UInt32(blob[17]) << 8) | (UInt32(blob[18]) << 16) | (UInt32(blob[19]) << 24)
        let modLen = bitLen / 8
        guard blob.count >= 20 + modLen else { return nil }

        // Windows: küçük-endian modulus → büyük-endian (Android `.reversedArray()` paritesi)
        let modulus = Array(blob[20..<(20 + modLen)].reversed())

        // Exponent büyük-endian, başındaki sıfırları at
        var expBytes: [UInt8] = [
            UInt8((expLE >> 24) & 0xFF), UInt8((expLE >> 16) & 0xFF),
            UInt8((expLE >>  8) & 0xFF), UInt8(expLE & 0xFF)
        ]
        while expBytes.first == 0x00, expBytes.count > 1 { expBytes.removeFirst() }

        // PKCS#1 RSAPublicKey DER → SecKeyCreateWithData
        let derData = buildPkcs1DER(modulus: modulus, exponent: expBytes)
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(derData as CFData,
                                    [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                     kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary,
                                    &error)
    }

    /// SEQUENCE { INTEGER(modulus) INTEGER(exponent) } — PKCS#1 RSAPublicKey DER encoding.
    private static func buildPkcs1DER(modulus: [UInt8], exponent: [UInt8]) -> Data {
        func asn1Int(_ b: [UInt8]) -> [UInt8] {
            var v = b
            if v.first.map({ $0 & 0x80 != 0 }) ?? false { v.insert(0x00, at: 0) }
            return [0x02] + encLen(v.count) + v
        }
        func encLen(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var l = n; var b: [UInt8] = []
            while l > 0 { b.insert(UInt8(l & 0xFF), at: 0); l >>= 8 }
            return [UInt8(0x80 | b.count)] + b
        }
        let body = asn1Int(modulus) + asn1Int(exponent)
        return Data([0x30] + encLen(body.count) + body)
    }

    // MARK: - Kontrol 1b: COSE_Sign1 imzası (ES384, leaf sertifika)

    /// COSE_Sign1 imzasını leaf sertifikanın public key'iyle doğrular (AWS Nitro = ES384).
    /// Sig_structure = ["Signature1", protected(bstr), external_aad(boş bstr), payload(bstr)].
    private static func verifyCoseSignature(protectedHeader: [UInt8], payload: [UInt8],
                                            signature: [UInt8], payloadMap: [CBOR: CBOR]) -> (Bool, String) {
        guard case let .byteString(leafBytes)? = payloadMap[.utf8String("certificate")],
              let leafCert = SecCertificateCreateWithData(nil, Data(leafBytes) as CFData),
              let pubKey = SecCertificateCopyKey(leafCert) else {
            return (false, "Leaf public key alınamadı")
        }

        // RFC 8152 §4.4 Sig_structure — sıra/tipler birebir COSE_Sign1 imzasıyla eşleşmeli.
        let sigStructure = CBOR.array([
            .utf8String("Signature1"),
            .byteString(protectedHeader),
            .byteString([]),
            .byteString(payload)
        ])
        let toBeSigned = Data(sigStructure.encode())

        // COSE imzası ham r‖s (P-384 → 96 bayt); SecKeyVerifySignature X9.62 DER bekler → çevir.
        guard let derSig = Self.ecRawToDer(signature) else {
            return (false, "İmza DER'e çevrilemedi")
        }
        let algo = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA384
        guard SecKeyIsAlgorithmSupported(pubKey, .verify, algo) else {
            return (false, "ECDSA P-384/SHA-384 desteklenmiyor")
        }
        var err: Unmanaged<CFError>?
        if SecKeyVerifySignature(pubKey, algo, toBeSigned as CFData, derSig as CFData, &err) {
            return (true, "OK")
        }
        return (false, err?.takeRetainedValue().localizedDescription ?? "İmza uyuşmazlığı")
    }

    /// Ham ECDSA imzası (r‖s, sabit boy) → ASN.1 DER SEQUENCE{INTEGER r, INTEGER s}.
    private static func ecRawToDer(_ raw: [UInt8]) -> Data? {
        guard raw.count >= 2, raw.count % 2 == 0 else { return nil }
        let half = raw.count / 2
        func asn1Int(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
            var v = Array(bytes)
            while v.count > 1, v.first == 0x00 { v.removeFirst() }     // baştaki sıfırları at
            if (v.first ?? 0) & 0x80 != 0 { v.insert(0x00, at: 0) }    // pozitif işaret koruması
            return [0x02, UInt8(v.count)] + v                          // P-384 → tek-bayt uzunluk yeterli
        }
        let body = asn1Int(raw[0..<half]) + asn1Int(raw[half..<raw.count])
        if body.count < 0x80 {
            return Data([0x30, UInt8(body.count)] + body)
        }
        return Data([0x30, 0x81, UInt8(body.count)] + body)
    }

    // MARK: - PCR0 + enclave pub key çıkarımı

    private static func extractPcr0(payloadMap: [CBOR: CBOR]) -> String {
        let pcrsVal = payloadMap[.unsignedInt(4)] ?? payloadMap[.utf8String("pcrs")]
        guard case let .map(pcrs)? = pcrsVal,
              case let .byteString(pcr0)? = pcrs[.unsignedInt(0)] else { return "UNKNOWN" }
        return pcr0.map { String(format: "%02x", $0) }.joined()
    }

    private static func extractEnclavePubKey(payloadMap: [CBOR: CBOR]) -> String? {
        guard case let .byteString(udBytes)? = payloadMap[.utf8String("user_data")],
              !udBytes.isEmpty else { return nil }
        return String(bytes: udBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SHA-256 hex

    private static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
