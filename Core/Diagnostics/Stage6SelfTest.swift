import Foundation
import CryptoKit
import DeviceCheck

/// Aşama 6 (Settings/Help/Security/Consent + App Attest) deterministik doğrulaması. Cihazda dev env
/// butonuyla koşar; CI'da KOŞMAZ ([[feedback_ios_codemagic_no_ci_tests]]). Kapsam: App Attest
/// clientDataHash konvansiyonu (sunucu paritesi), token zarf round-trip, enroll isteği anahtar şeması,
/// enclave attestation PCR0 CBOR çıkarımı (+ graceful fallback), dil tercihi round-trip.
/// `SelfTestResult` Stage1'de tanımlı.
enum Stage6SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        // ── App Attest desteği (bilgi — simülatörde false beklenir) ──
        r.append(check("App Attest desteği (cihaz bilgisi)") {
            let supported = DCAppAttestService.shared.isSupported
            return (true, "isSupported: \(supported)")
        })

        // ── clientDataHash = SHA256(utf8(challenge)) — sunucu ClientAttestationGate ile birebir ──
        r.append(check("clientDataHash = SHA256(challenge) konvansiyonu") {
            let challenge = "abc"
            let hash = SHA256.hash(data: Data(challenge.utf8)).map { String(format: "%02x", $0) }.joined()
            let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            return (hash == expected, hash == expected ? "ok" : "mismatch: \(hash)")
        })

        // ── AppAttestToken: JSON → base64 → JSON round-trip (X-App-Attest başlığı parite) ──
        r.append(check("AppAttestToken zarf round-trip (base64 JSON)") {
            let token = AppAttestToken(keyId: "key-123", challenge: "chal-xyz", assertion: "YXNzZXJ0")
            let b64 = try JSONEncoder().encode(token).base64EncodedString()
            guard let data = Data(base64Encoded: b64) else { return (false, "base64 decode fail") }
            let back = try JSONDecoder().decode(AppAttestToken.self, from: data)
            let ok = back.keyId == token.keyId && back.challenge == token.challenge && back.assertion == token.assertion
            return (ok, ok ? "ok" : "mismatch")
        })

        // ── Enroll isteği JSON anahtarları (sunucu EnrollRequest case-insensitive bind) ──
        r.append(check("Enroll isteği anahtar şeması (keyId/attestation/challenge)") {
            let req = AppAttestEnrollRequest(keyId: "k", attestation: "a", challenge: "c")
            let json = String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
            let ok = json.contains("\"keyId\"") && json.contains("\"attestation\"") && json.contains("\"challenge\"")
            return (ok, ok ? "ok" : json)
        })

        // ── PCR0 CBOR çıkarımı: elle kurulmuş COSE_Sign1 [_, _, payload{4:{0:bstr(aabb)}}, _] ──
        r.append(check("EnclaveAttestation.extractPcr0 (sentetik COSE_Sign1)") {
            // 84 40 A0 47 (A1 04 A1 00 42 AA BB) 40  → pcrs[0] = 0xAA 0xBB
            let cbor: [UInt8] = [0x84, 0x40, 0xA0, 0x47, 0xA1, 0x04, 0xA1, 0x00, 0x42, 0xAA, 0xBB, 0x40]
            let b64 = Data(cbor).base64EncodedString()
            let pcr0 = EnclaveAttestation.extractPcr0(fromBase64: b64)
            return (pcr0 == "aabb", "pcr0=\(pcr0 ?? "nil")")
        })

        // ── PCR0 graceful fallback: mock/bozuk belge → nil (çökme yok) ──
        r.append(check("extractPcr0 graceful fallback (nil/garbage → nil)") {
            let a = EnclaveAttestation.extractPcr0(fromBase64: nil)
            let b = EnclaveAttestation.extractPcr0(fromBase64: "not-base64-!!!")
            let c = EnclaveAttestation.extractPcr0(fromBase64: Data([0xA1, 0x00, 0x01]).base64EncodedString()) // düz map
            let ok = a == nil && b == nil && c == nil
            return (ok, ok ? "hepsi nil" : "a=\(a ?? "-") b=\(b ?? "-") c=\(c ?? "-")")
        })

        // ── Dil tercihi round-trip (AppPrefs.appLanguage) — yan etkisiz (save/restore) ──
        r.append(check("Dil tercihi round-trip") {
            let original = AppPrefs.appLanguage
            defer { AppPrefs.appLanguage = original }
            AppPrefs.appLanguage = "en"
            let ok = AppPrefs.appLanguage == "en"
            return (ok, ok ? "ok" : "mismatch")
        })

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
