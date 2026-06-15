import Foundation
import GRDB

/// Aşama 4 (Storage / GRDB / Payload) deterministik doğrulaması. Cihazda dev env butonuyla koşar,
/// sonuç ekrana + Sentry'e yazılır — CI'da KOŞMAZ ([[feedback_ios_codemagic_no_ci_tests]]).
/// Biyometrik user-key decrypt'i (Face ID promptu) kapsanmaz; OAEP-SHA1 Keychain decrypt yolu
/// biyometriksiz **history key** ile kanıtlanır (aynı kod yolu). `SelfTestResult` Stage1'de tanımlı.
enum Stage4SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        // ── Keychain OAEP-SHA1 round-trip (history key — user key ile aynı algoritma) ──
        r.append(check("KeychainKeyStore OAEP-SHA1 encrypt→decrypt (history key)") {
            let pub = try KeychainKeyStore.ensureHistoryKey()
            let secret = "verifyblind-roundtrip-\(UUID().uuidString)"
            let enc = try CryptoUtils.rsaEncryptForKeystore(secret, publicKeyBase64: pub)
            let dec = try KeychainKeyStore.decryptWithHistoryKey(enc)
            return (dec == secret, dec == secret ? "ok" : "mismatch")
        })

        // ── GRDB history: insert → fetch (decrypt) → revoke → markDeleted ──
        r.append(check("GRDB history insert/fetch/revoke/delete + şifreleme") {
            let testDb = try AppDatabase(DatabaseQueue())   // bellek-içi migrated DB
            let repo = HistoryRepository(db: testDb.dbQueue)
            let nonce = UUID().uuidString
            repo.insert(title: "Test Başlık", description: "Test Açıklama",
                        status: 1, actionType: .sharedIdentity, nonce: nonce,
                        personId: "p1", cardId: "c1", partnerId: "Acme")
            let all = repo.fetchAll(currentCardId: "c1")
            guard let rec = all.first(where: { $0.nonce == nonce }), let id = rec.id else {
                return (false, "kayıt bulunamadı")
            }
            let decOk = rec.title == "Test Başlık" && rec.description == "Test Açıklama"
            repo.updateRevokeTime(id: id, time: 123)
            let afterRevoke = repo.findByNonce(nonce)
            let revokeOk = afterRevoke?.revokeTime == 123
            repo.markDeleted(id: id)
            let afterDelete = repo.fetchAll(currentCardId: "c1").contains { $0.nonce == nonce }
            return (decOk && revokeOk && !afterDelete,
                    "dec=\(decOk) revoke=\(revokeOk) deletedHidden=\(!afterDelete)")
        })

        // ── cardId filtresi: farklı karta ait kayıt gizlenir ──
        r.append(check("GRDB history cardId filtresi") {
            let testDb = try AppDatabase(DatabaseQueue())
            let repo = HistoryRepository(db: testDb.dbQueue)
            repo.insert(title: "A", description: "a", status: 1, nonce: UUID().uuidString, cardId: "card-X")
            repo.insert(title: "B", description: "b", status: 1, nonce: UUID().uuidString, cardId: "")  // eski/boş
            let visible = repo.fetchAll(currentCardId: "card-Y") // X gizli, boş görünür
            let ok = visible.count == 1 && visible.first?.title == "B"
            return (ok, "görünen=\(visible.count)")
        })

        // ── SecureStore round-trip (orijinal değerleri koru/geri yükle) ──
        r.append(check("SecureStore saveIds/get round-trip") {
            let origP = SecureStore.getPersonId()
            let origC = SecureStore.getCardId()
            defer {
                if let origP, let origC { SecureStore.saveIds(personId: origP, cardId: origC) }
                else { SecureStore.clear() }
            }
            SecureStore.saveIds(personId: "test_p", cardId: "test_c")
            let ok = SecureStore.getPersonId() == "test_p" && SecureStore.getCardId() == "test_c"
            return (ok, ok ? "ok" : "mismatch")
        })

        // ── Expiry formatlama ──
        r.append(check("ExpiryFormatter: 301231 (yyMMdd) → 31/12/2030") {
            let f = ExpiryFormatter.format("301231")
            return (f == "31/12/2030", f)
        })
        r.append(check("ExpiryFormatter: 20301231 (yyyyMMdd) → 31/12/2030") {
            let f = ExpiryFormatter.format("20301231")
            return (f == "31/12/2030", f)
        })
        r.append(check("ExpiryFormatter: boş → —") {
            (ExpiryFormatter.format("") == "—", "ok")
        })

        // ── TCKN maskeleme ──
        r.append(check("Masker.mask: 11 haneli → 12*******01") {
            let m = Masker.mask("12345678901")
            return (m == "12*******01", m)
        })

        // ── QR/deeplink parse ──
        r.append(check("QRPayloadParser: deeplink nonce+pk_hash") {
            let p = QRPayloadParser.parse("https://app.verifyblind.com/request?nonce=abc123&pk_hash=xyz")
            return (p?.nonce == "abc123" && p?.pkHash == "xyz", "\(String(describing: p))")
        })
        r.append(check("QRPayloadParser: JSON fallback (pk yok)") {
            let p = QRPayloadParser.parse("{\"nonce\":\"n9\"}")
            return (p?.nonce == "n9" && p?.pkHash == nil, "\(String(describing: p))")
        })
        r.append(check("QRPayloadParser: geçersiz → nil") {
            (QRPayloadParser.parse("merhaba dünya") == nil, "ok")
        })

        // ── JSON şekli: SecurePayload PascalCase wire anahtarları ──
        r.append(check("SecurePayload JSON: PascalCase anahtarlar") {
            let p = SecurePayload(sod: "s", dg1: "d", activeSig: "a", userPubKey: "k")
            let keys = try jsonKeys(p)
            let ok = keys.contains("SOD") && keys.contains("DG1") && keys.contains("UserPubKey")
                && keys.contains("IntegrityToken") && !keys.contains("sod")
            return (ok, keys.sorted().prefix(6).joined(separator: ","))
        })

        // ── JSON şekli: HybridContent enc_key/blob ──
        r.append(check("HybridContent JSON: enc_key + blob") {
            let h = HybridContent(encKey: "e", blob: "b")
            let keys = try jsonKeys(h)
            return (keys.contains("enc_key") && keys.contains("blob"), keys.sorted().joined(separator: ","))
        })

        // ── Login sarmalı: signed_ticket gömülü + nonce + pk_hash ──
        r.append(check("Login wrapper: signed_ticket(obj)+nonce+pk_hash") {
            let ticketJson = "{\"Payload\":{\"TCKN\":\"x\"},\"Signature\":\"sig\"}"
            let wrapper = try LoginWrapperBuilder.build(signedTicketJson: ticketJson, nonce: "N1", pkHash: "PK")
            let obj = try JSONSerialization.jsonObject(with: Data(wrapper.utf8)) as? [String: Any]
            let st = obj?["signed_ticket"] as? [String: Any]
            let ok = obj?["nonce"] as? String == "N1" && obj?["pk_hash"] as? String == "PK"
                && (st?["Signature"] as? String) == "sig"
            return (ok, "keys=\(obj?.keys.sorted() ?? [])")
        })

        // ── UnifiedRegistrationPayload decode (person_id/card_id snake_case) ──
        r.append(check("UnifiedRegistrationPayload decode") {
            let json = """
            {"ticket":{"Payload":{"TCKN":"11111111111","Ad":"A","Soyad":"B","SeriNo":"S1","UserPubKey":"K","GecerlilikTarihi":"301231"},"Signature":"sig"},"person_id":"pid","card_id":"cid"}
            """
            let u = try JSONDecoder().decode(UnifiedRegistrationPayload.self, from: Data(json.utf8))
            let ok = u.personId == "pid" && u.cardId == "cid"
                && u.ticket.payload.tckn == "11111111111" && u.ticket.payload.gecerlilikTarihi == "301231"
            return (ok, "person=\(u.personId) card=\(u.cardId)")
        })

        let passed = r.filter { $0.passed }.count
        if passed == r.count {
            Log.info("Stage4 self-test: \(passed)/\(r.count) PASSED", category: .flow)
        } else {
            Log.error("Stage4 self-test: \(passed)/\(r.count) passed — \(r.count - passed) FAILED", category: .flow)
            for f in r where !f.passed { Log.error("Stage4 FAIL: \(f.name) — \(f.detail)", category: .flow) }
        }
        return r
    }

    // MARK: - Yardımcılar

    private static func jsonKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Set(obj.keys)
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
