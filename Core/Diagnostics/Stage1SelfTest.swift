import Foundation

/// Tek bir self-test adımının sonucu.
struct SelfTestResult: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
}

/// Aşama 1 (Core/Network + Core/Crypto) doğrulaması — **CI XCTest yerine** uygulama içi self-test.
///
/// Mac yok + Codemagic dakikaları pahalı olduğu için kritik mantık burada, cihazda,
/// DEBUG butonuyla doğrulanır; sonuçlar ekrana + Sentry'e (`Log`) yazılır. Fonksiyonlar saf →
/// ileride Mac olursa XCTest'ten çağrılabilir. Bkz. `feedback_ios_codemagic_no_ci_tests`.
enum Stage1SelfTest {

    /// Throwaway RSA-2048 SPKI (base64) — .NET `ExportSubjectPublicKeyInfo` ile üretildi
    /// (sunucunun ürettiği formatla aynı). SPKI→SecKey ayrıştırmasını doğrulamak için; gizli değil.
    private static let testSPKI =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsNnGokGUijPIPjQ55ENT" +
        "/RXq02PstVkl50p6kl1hvmxFd2lCulGLPNkzzu9E/G0qn+iOVV+eojxctjmr8Wfs+ii" +
        "UM5kEAsQkXk6ODHMyANAOJK89iY2VCcwuns8G5AbDX5nvPRWCKBOjXdFeUX60Xt25z/" +
        "go8ahbt9NqeuiVZQLNw0HQLMUKyJcNvNTSYyJEd0hxVVEKxF4dniR7qqS9UB9xO1lUV" +
        "Kucv0dAihobTIGvQkNKAF+BodC7Mi/Ojb6/AVkQ+C/Wp5qqiM2hc17DQTfcJEIexI0K" +
        "Pcv7kGk2Ic9+Hn4kpoqeKIbHmkPAgQ+gSoORFKOwGf28mkQB55Av9QIDAQAB"

    private static let sha256AbcVector =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    // MARK: - Tümü

    static func runAll() async -> [SelfTestResult] {
        var all = runOffline()
        all += await runOnline()
        let passed = all.filter { $0.passed }.count
        if passed == all.count {
            Log.info("Stage1 self-test: \(passed)/\(all.count) PASSED", category: .flow)
        } else {
            Log.error("Stage1 self-test: \(passed)/\(all.count) passed — \(all.count - passed) FAILED", category: .flow)
        }
        return all
    }

    // MARK: - Offline (deterministik, ağ yok)

    static func runOffline() -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        results.append(check("SHA-256(\"abc\") vektör") {
            let h = CryptoUtils.sha256("abc")
            return (h == sha256AbcVector, h)
        })

        results.append(check("SHA-256 bytes uzunluğu") {
            let n = CryptoUtils.sha256Bytes("abc").count
            return (n == 32, "\(n) byte")
        })

        results.append(check("AES-GCM round-trip (rastgele key)") {
            let secret = "VerifyBlind-Aşama1-AES-round-trip-✓"
            let (blob, key) = try CryptoUtils.aesEncrypt(secret)
            let back = try CryptoUtils.aesDecrypt(blobBase64: blob, keyBase64: key)
            return (back == secret, "blob/key base64 üretildi")
        })

        results.append(check("AES-GCM round-trip (personId key)") {
            let pid = "12345678901"
            let (ct, iv) = try CryptoUtils.aesGcmEncrypt("cloud-sync-payload", personId: pid)
            let back = try CryptoUtils.aesGcmDecrypt(ciphertextBase64: ct, ivBase64: iv, personId: pid)
            return (back == "cloud-sync-payload", "iv=\(iv)")
        })

        results.append(check("SPKI → SecKey parse") {
            let key = RSAKey.publicKey(fromSPKIBase64: testSPKI)
            return (key != nil, key != nil ? "SecKey oluşturuldu" : "nil")
        })

        results.append(check("RSA-OAEP-SHA256 encrypt boyutu") {
            let cipher = try CryptoUtils.rsaEncrypt("handshake-nonce", publicKeyBase64: testSPKI)
            let n = CryptoUtils.decodeBase64(cipher)?.count ?? -1
            return (n == 256, "\(n) byte")
        })

        results.append(check("RSA-OAEP-SHA1 encrypt boyutu") {
            let cipher = try CryptoUtils.rsaEncryptForKeystore("ticket-key", publicKeyBase64: testSPKI)
            let n = CryptoUtils.decodeBase64(cipher)?.count ?? -1
            return (n == 256, "\(n) byte")
        })

        results.append(check("DTO: RegistrationRequest snake_case") {
            let req = RegistrationRequest(encryptedKey: "K", aesBlob: "B", countryIsoCode: "TR")
            let data = try JSONEncoder().encode(req)
            let json = String(decoding: data, as: UTF8.self)
            let back = try JSONDecoder().decode(RegistrationRequest.self, from: data)
            let ok = back.encryptedKey == "K" && back.aesBlob == "B"
                && json.contains("\"encrypted_key\"") && json.contains("\"aes_blob\"")
            return (ok, "anahtarlar snake_case")
        })

        results.append(check("DTO: HybridContent enc_key/blob") {
            let hc = HybridContent(encKey: "EK", blob: "BL")
            let json = String(decoding: try JSONEncoder().encode(hc), as: UTF8.self)
            return (json.contains("\"enc_key\"") && json.contains("\"blob\""), json)
        })

        results.append(check("DTO: HandshakeResponse decode") {
            let sample = #"{"nonce":"abc","timestamp":123,"nonce_signature":"sig","enclave_pub_key":"k","challenges":[1,2]}"#
            let resp = try JSONDecoder().decode(HandshakeResponse.self, from: Data(sample.utf8))
            let ok = resp.nonce == "abc" && resp.timestamp == 123 && resp.challenges == [1, 2]
            return (ok, "nonce=\(resp.nonce)")
        })

        logResults(results, group: "offline")
        return results
    }

    // MARK: - Online (ağ — butonla)

    static func runOnline() async -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        do {
            let cfg = try await VerifyAPI.shared.appConfig()
            let detail = "env=\(cfg.environment ?? "?") iosMin=\(cfg.minimumIosVersion ?? "—")"
            results.append(SelfTestResult(name: "GET app-config", passed: true, detail: detail))
            Log.info("SelfTest app-config OK: \(detail)", category: .network)
        } catch {
            results.append(SelfTestResult(name: "GET app-config", passed: false, detail: error.localizedDescription))
            Log.error("SelfTest app-config başarısız", error: error, category: .network)
        }

        do {
            let hs = try await VerifyAPI.shared.handshake()
            let keyParsed = hs.enclavePubKey.flatMap { RSAKey.publicKey(fromSPKIBase64: $0) } != nil
            let detail = "nonce=\(hs.nonce.prefix(8))… enclaveKeyParsed=\(keyParsed)"
            results.append(SelfTestResult(name: "POST handshake + enclave key parse", passed: keyParsed, detail: detail))
            if keyParsed {
                Log.info("SelfTest handshake OK: \(detail)", category: .network)
            } else {
                Log.error("SelfTest handshake: enclave_pub_key parse edilemedi", category: .crypto)
            }
        } catch {
            results.append(SelfTestResult(name: "POST handshake + enclave key parse", passed: false, detail: error.localizedDescription))
            Log.error("SelfTest handshake başarısız", error: error, category: .network)
        }

        return results
    }

    // MARK: - Yardımcılar

    private static func check(_ name: String, _ body: () throws -> (Bool, String)) -> SelfTestResult {
        do {
            let (passed, detail) = try body()
            return SelfTestResult(name: name, passed: passed, detail: detail)
        } catch {
            return SelfTestResult(name: name, passed: false, detail: "throw: \(error)")
        }
    }

    private static func logResults(_ results: [SelfTestResult], group: String) {
        for r in results where !r.passed {
            Log.error("SelfTest[\(group)] FAIL: \(r.name) — \(r.detail)", category: .crypto)
        }
        let passed = results.filter { $0.passed }.count
        Log.debug("SelfTest[\(group)]: \(passed)/\(results.count) passed", category: .flow)
    }
}
