import Foundation
import Security
import CryptoKit
import GRDB

/// Aşama 5 (Backup) deterministik doğrulaması. Cihazda dev env butonuyla koşar; CI'da KOŞMAZ
/// ([[feedback_ios_codemagic_no_ci_tests]]). Kapsam: personId-AES-GCM çapraz-platform şifreleme,
/// bulut yedek JSON şema/anahtar paritesi (Android Gson), GRDB DB'nin iCloud yedeğinden hariç
/// tutulması + keychain ThisDeviceOnly (auto-backup koruması), HistoryRepository sync zinciri.
/// `SelfTestResult` Stage1'de tanımlı.
enum Stage5SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        // ── AES-GCM(personId) round-trip (çapraz platform: Android aesGcmDecrypt ile aynı) ──
        r.append(check("AES-GCM(personId) encrypt→decrypt round-trip") {
            let pid = "pid-\(UUID().uuidString)"
            let plain = "Merhaba VerifyBlind 🔐"
            let pair = try CryptoUtils.aesGcmEncrypt(plain, personId: pid)
            let dec = try CryptoUtils.aesGcmDecrypt(ciphertextBase64: pair.ciphertext, ivBase64: pair.iv, personId: pid)
            return (dec == plain, dec == plain ? "ok" : "mismatch")
        })

        // ── Yanlış personId çözememeli (kişiye-özel anahtar kanıtı) ──
        r.append(check("AES-GCM(personId) yanlış personId reddi") {
            let pair = try CryptoUtils.aesGcmEncrypt("gizli", personId: "kisi-A")
            do {
                _ = try CryptoUtils.aesGcmDecrypt(ciphertextBase64: pair.ciphertext, ivBase64: pair.iv, personId: "kisi-B")
                return (false, "yanlış key çözdü!")
            } catch {
                return (true, "reddedildi")
            }
        })

        // ── deriveKeyFromPersonId == SHA256(personId) (Android deriveKeyFromPersonId paritesi) ──
        r.append(check("Key derivation = SHA256(personId)") {
            let pid = "deterministic-person"
            let keyBytes = CryptoUtils.deriveKeyFromPersonId(pid).withUnsafeBytes { Data($0) }
            let sha = CryptoUtils.sha256Bytes(pid)
            return (keyBytes == sha, keyBytes == sha ? "ok" : "mismatch")
        })

        // ── Tam yedek öğesi round-trip: InnerPayload→enc→CloudPayload JSON→parse→decrypt ──
        r.append(check("Backup öğesi tam round-trip (encrypt→payload→parse→decrypt)") {
            let pid = "pid-roundtrip"
            let inner = InnerPayload(title: "Doğrulama Tamamlandı", description: "Partner: Acme",
                                     cardId: "card-1", personId: pid, timestamp: 1_700_000_000_000,
                                     nonce: "nonce-1", partnerId: "Acme")
            let innerJson = String(decoding: try JSONEncoder().encode(inner), as: UTF8.self)
            let pair = try CryptoUtils.aesGcmEncrypt(innerJson, personId: pid)
            let item = CloudHistoryItem(enc: pair.ciphertext, iv: pair.iv, actionType: 2, status: 1, transactionId: nil)
            let payload = CloudPayload(history: [item], partners: nil)
            let payloadJson = try JSONEncoder().encode(payload)
            // parse back
            let parsed = try JSONDecoder().decode(CloudPayload.self, from: payloadJson)
            guard let first = parsed.history?.first else { return (false, "history boş") }
            let decJson = try CryptoUtils.aesGcmDecrypt(ciphertextBase64: first.enc, ivBase64: first.iv, personId: pid)
            let decInner = try JSONDecoder().decode(InnerPayload.self, from: Data(decJson.utf8))
            let ok = decInner.nonce == "nonce-1" && decInner.title == inner.title
                && decInner.personId == pid && decInner.timestamp == inner.timestamp
            return (ok, "nonce=\(decInner.nonce) title=\(decInner.title)")
        })

        // ── CloudPayload/CloudHistoryItem JSON anahtarları (Android Gson birebir) ──
        r.append(check("CloudPayload JSON anahtarları: history/partners/enc/iv/actionType/status") {
            let item = CloudHistoryItem(enc: "e", iv: "i", actionType: 2, status: 1, transactionId: "t")
            let partner = BackupPartnerItem(from: PartnerItem(partnerId: "p1", name: "Acme", logoUrl: "u", logoBase64: nil, timestamp: 9))
            let payload = CloudPayload(history: [item], partners: ["p1": partner])
            let top = try jsonKeys(payload)
            let itemKeys = try jsonKeys(item)
            let partnerKeys = try jsonKeys(partner)
            let ok = top.contains("history") && top.contains("partners")
                && itemKeys.isSuperset(of: ["enc", "iv", "actionType", "status"])
                && partnerKeys.isSuperset(of: ["id", "name", "lastUpdated"])
            return (ok, "top=\(top.sorted()) item=\(itemKeys.sorted())")
        })

        // ── InnerPayload JSON anahtarları (Android InnerPayload alan adları) ──
        r.append(check("InnerPayload JSON anahtarları") {
            let inner = InnerPayload(title: "t", description: "d", cardId: "c", personId: "p",
                                     timestamp: 1, nonce: "n", partnerId: "pp")
            let keys = try jsonKeys(inner)
            let ok = keys.isSuperset(of: ["title", "description", "cardId", "personId", "timestamp", "nonce"])
            return (ok, keys.sorted().joined(separator: ","))
        })

        // ── BackupPartnerItem ↔ iOS PartnerItem dönüşümü (alan adı farkı: partnerId/id, timestamp/lastUpdated) ──
        r.append(check("BackupPartnerItem ↔ PartnerItem dönüşüm") {
            let local = PartnerItem(partnerId: "p1", name: "Acme", logoUrl: "u", logoBase64: nil, timestamp: 42)
            let backup = BackupPartnerItem(from: local)
            let back = backup.toPartnerItem()
            let ok = backup.id == "p1" && backup.lastUpdated == 42 && back.partnerId == "p1" && back.timestamp == 42
            return (ok, "id=\(backup.id) lastUpdated=\(backup.lastUpdated)")
        })

        // ── ZKP: GRDB DB iCloud cihaz yedeğinden hariç (isExcludedFromBackup) ──
        r.append(check("GRDB DB iCloud yedeğinden hariç (isExcludedFromBackup)") {
            guard let url = AppDatabase.fileURL else { return (true, "bellek-içi DB (atlandı)") }
            let excluded = BackupExclusion.isExcluded(url)
            return (excluded, excluded ? "hariç ✓" : "DB yedekleniyor!")
        })

        // ── ZKP: ThisDeviceOnly keychain item'ı iCloud Keychain'e senkron OLMAZ (synchronizable=false) ──
        r.append(check("Keychain ThisDeviceOnly → synchronizable=false (auto-backup koruması)") {
            let service = "app.verifyblind.ios.stage5probe"
            let account = "probe"
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data("x".utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly  // SecureStore ile aynı
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            defer { SecItemDelete(base as CFDictionary) }
            guard addStatus == errSecSuccess else { return (false, "add OSStatus \(addStatus)") }
            var query = base
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let st = SecItemCopyMatching(query as CFDictionary, &item)
            guard st == errSecSuccess, let attrs = item as? [String: Any] else { return (false, "copy OSStatus \(st)") }
            let accessible = attrs[kSecAttrAccessible as String] as? String
            let sync = (attrs[kSecAttrSynchronizable as String] as? Bool) ?? false
            let accessibleOK = accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            return (accessibleOK && !sync, "accessible=\(accessible ?? "?") sync=\(sync)")
        })

        // ── HistoryRepository sync zinciri (insert→snapshot→nonces→markSent→sent→tombstone→cleanup) ──
        r.append(check("HistoryRepository sync zinciri") {
            let testDb = try AppDatabase(DatabaseQueue())   // bellek-içi migrated DB
            let repo = HistoryRepository(db: testDb.dbQueue)
            let nonce = UUID().uuidString
            repo.insert(title: "T", description: "D", status: 1, actionType: .sharedIdentity,
                        nonce: nonce, personId: "pid", cardId: "c1", partnerId: "Acme")
            let inSnap = repo.getAllHistorySnapshot().contains { $0.nonce == nonce && $0.title == "T" }
            let inNonces = repo.getAllNonces().contains(nonce)
            repo.markAsSent([nonce])
            let inSent = repo.getSentItems().contains { $0.nonce == nonce }
            repo.markDeletedByNonce(nonce)
            let inDeleted = repo.getDeletedNonces().contains(nonce)
            repo.markAsSent([nonce])               // SyncManager: tombstone'u gönderildi işaretle
            repo.cleanupSyncedTombstones()
            let goneAfterCleanup = !repo.getAllNonces().contains(nonce)
            let ok = inSnap && inNonces && inSent && inDeleted && goneAfterCleanup
            return (ok, "snap=\(inSnap) sent=\(inSent) del=\(inDeleted) cleaned=\(goneAfterCleanup)")
        })

        // ── HistoryRepository.insertCloudItem: çözülmüş bulut öğesini yerele yaz (yeniden şifreli, isSent) ──
        r.append(check("HistoryRepository.insertCloudItem (re-encrypt + isSent)") {
            let testDb = try AppDatabase(DatabaseQueue())
            let repo = HistoryRepository(db: testDb.dbQueue)
            let rec = HistoryRecord(id: nil, title: "PlainTitle", description: "PlainDesc",
                                    actionType: 2, status: 1, timestamp: 123, transactionId: nil,
                                    nonce: UUID().uuidString, personId: "pid", cardId: "c1",
                                    partnerId: "Acme", isSent: false, isDeleted: false, revokeTime: nil)
            repo.insertCloudItem(rec)
            let raw = repo.findByNonce(rec.nonce)
            let decrypted = repo.getAllHistorySnapshot().first { $0.nonce == rec.nonce }
            let ok = raw?.isSent == true && raw?.title != "PlainTitle" && decrypted?.title == "PlainTitle"
            return (ok, "isSent=\(raw?.isSent ?? false) decTitle=\(decrypted?.title ?? "nil")")
        })

        let passed = r.filter { $0.passed }.count
        if passed == r.count {
            Log.info("Stage5 self-test: \(passed)/\(r.count) PASSED", category: .flow)
        } else {
            Log.error("Stage5 self-test: \(passed)/\(r.count) passed — \(r.count - passed) FAILED", category: .flow)
            for f in r where !f.passed { Log.error("Stage5 FAIL: \(f.name) — \(f.detail)", category: .flow) }
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
