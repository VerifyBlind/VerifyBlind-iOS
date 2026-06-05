import Foundation

/// Aşama 2 (NFC) deterministik doğrulaması.
///
/// Gerçek çip okuma ancak fiziksel kart + cihazda yapılabilir (`NFCTestView`); bu self-test
/// yalnızca SAF mantığı kanıtlar: MRZ anahtarı (ICAO check digit), giriş temizleme, AA challenge
/// türetme ve `ScannedPassport → SecurePayload` alan/base64 eşlemesi (sunucu sözleşmesi).
/// CI'da KOŞMAZ; cihazda dev env butonuyla çalışır. Bkz. `feedback_ios_codemagic_no_ci_tests`.
/// `SelfTestResult` tipi `Stage1SelfTest.swift`'te tanımlı (paylaşılır).
enum Stage2SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        r.append(check("cleanDocNo: boşluk + küçük harf") {
            let out = MRZKey.cleanDocNo("a12 345 6")
            return (out == "A123456", out)
        })

        r.append(check("correctDateInput: 01.05.1990 → 900501") {
            let out = MRZKey.correctDateInput("01.05.1990")
            return (out == "900501", out)
        })

        r.append(check("correctDateInput: OCR OI/O5/199O → 900501") {
            let out = MRZKey.correctDateInput("OI/O5/199O")
            return (out == "900501", out)
        })

        r.append(check("correctDateInput: 6 hane YYMMDD korunur") {
            let out = MRZKey.correctDateInput("690806")
            return (out == "690806", out)
        })

        // ICAO Doc 9303 bilinen vektör: L898902C< / 690806 / 940623 → check digit'ler 3 / 1 / 6.
        r.append(check("mrzKey: ICAO Doc 9303 vektörü") {
            let key = MRZKey.mrzKey(documentNumber: "L898902C", dateOfBirth: "690806", dateOfExpiry: "940623")
            return (key == "L898902C<369080619406236", key)
        })

        r.append(check("AA challenge = SHA-256(nonce)[:8] (8B, deterministik)") {
            let c1 = Array(CryptoUtils.sha256Bytes("handshake-nonce").prefix(8))
            let c2 = Array(CryptoUtils.sha256Bytes("handshake-nonce").prefix(8))
            let expected = Array(CryptoUtils.sha256Bytes("handshake-nonce"))[0..<8]
            return (c1.count == 8 && c1 == c2 && c1 == Array(expected), "\(c1.count) bayt")
        })

        r.append(check("ScannedPassport → SecurePayload (base64 + PascalCase)") {
            let sp = ScannedPassport(
                sod: Data([1, 2, 3]), dg1: Data([4, 5, 6]), dg15: Data([7]),
                faceImage: Data([8, 9]), activeAuthSignature: Data([10]),
                aaChallenge: Data([0xAA, 0xBB]), activeAuthPassed: true, activeAuthSupported: true,
                documentNumber: "X", nationality: "TUR", issuingState: "TUR", documentType: "ID"
            )
            let payload = sp.makeSecurePayload(userPubKey: "PUB", nonce: "N", timestamp: 42, nonceSignature: "SIG")
            let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            let ok = CryptoUtils.decodeBase64(payload.sod) == Data([1, 2, 3])
                && CryptoUtils.decodeBase64(payload.dg2Photo) == Data([8, 9])
                && payload.aaChallenge == Data([0xAA, 0xBB]).base64EncodedString()
                && payload.userPubKey == "PUB"
                && json.contains("\"SOD\"") && json.contains("\"DG1\"")
                && json.contains("\"DG15\"") && json.contains("\"ActiveSig\"")
                && json.contains("\"AAChallenge\"") && json.contains("\"DG2_Photo\"")
                && json.contains("\"UserPubKey\"")
            return (ok, ok ? "base64 + PascalCase OK" : "alan/anahtar uyuşmazlığı")
        })

        let passed = r.filter { $0.passed }.count
        if passed == r.count {
            Log.info("Stage2 self-test: \(passed)/\(r.count) PASSED", category: .flow)
        } else {
            Log.error("Stage2 self-test: \(passed)/\(r.count) passed — \(r.count - passed) FAILED", category: .flow)
            for f in r where !f.passed {
                Log.error("Stage2 FAIL: \(f.name) — \(f.detail)", category: .flow)
            }
        }
        return r
    }

    private static func check(_ name: String, _ body: () throws -> (Bool, String)) -> SelfTestResult {
        do {
            let (passed, detail) = try body()
            return SelfTestResult(name: name, passed: passed, detail: detail)
        } catch {
            return SelfTestResult(name: name, passed: false, detail: "throw: \(error)")
        }
    }
}
