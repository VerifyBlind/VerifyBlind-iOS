import Foundation
import GRDB

/// Android `data/HistoryRepository.kt` portu. title/description history key ile şifrelenir
/// (AES-256-GCM + RSA-OAEP-SHA1 sarmalı → SecureContent JSON); display'de çözülür. Decrypt
/// promptsuz (history key biyometriksiz). `timestamp`/`revokeTime` epoch ms.
final class HistoryRepository {
    static let shared = HistoryRepository()

    private let db: DatabaseQueue
    private lazy var historyPubKey: String? = try? KeychainKeyStore.ensureHistoryKey()

    init(db: DatabaseQueue = AppDatabase.shared.dbQueue) {
        self.db = db
    }

    private struct SecureContent: Codable { let key: String; let blob: String }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Yazma

    func insert(title: String,
                description: String,
                status: Int,
                actionType: HistoryAction = .generic,
                timestamp: Int64 = nowMs(),
                nonce: String = UUID().uuidString,
                personId: String = "",
                cardId: String = "",
                partnerId: String? = nil) {
        do {
            let encTitle = try encryptString(title)
            let encDesc = try encryptString(description)
            var rec = HistoryRecord(
                id: nil, title: encTitle, description: encDesc,
                actionType: actionType.rawValue, status: status, timestamp: timestamp,
                transactionId: nil, nonce: nonce, personId: personId, cardId: cardId,
                partnerId: partnerId, isSent: false, isDeleted: false, revokeTime: nil
            )
            try db.write { db in try rec.insert(db) }
            Log.info("History kaydı eklendi (tür \(actionType.rawValue))", category: .flow)
        } catch {
            Log.error("HistoryRepository.insert başarısız", error: error, category: .flow)
        }
    }

    func markDeleted(id: Int64) {
        do {
            try db.write { db in
                try db.execute(sql: "UPDATE history SET isDeleted = 1 WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.error("HistoryRepository.markDeleted başarısız", error: error, category: .flow)
        }
    }

    func updateRevokeTime(id: Int64, time: Int64 = nowMs()) {
        do {
            try db.write { db in
                try db.execute(sql: "UPDATE history SET revokeTime = ? WHERE id = ?", arguments: [time, id])
            }
        } catch {
            Log.error("HistoryRepository.updateRevokeTime başarısız", error: error, category: .flow)
        }
    }

    func deleteAll() {
        do { try db.write { db in _ = try HistoryRecord.deleteAll(db) } }
        catch { Log.error("HistoryRepository.deleteAll başarısız", error: error, category: .flow) }
    }

    // MARK: - Okuma

    /// Android `allHistory` + `HistoryFragment` cardId filtresi: silinmemiş, current cardId'e ait
    /// (veya cardId boş eski kayıtlar), timestamp DESC, title/description çözülmüş.
    func fetchAll(currentCardId: String?) -> [HistoryRecord] {
        do {
            let raw = try db.read { db in
                try HistoryRecord
                    .filter(Column("isDeleted") == false)
                    .order(Column("timestamp").desc)
                    .fetchAll(db)
            }
            let filtered = raw.filter { rec in
                rec.cardId.isEmpty || currentCardId == nil || rec.cardId == currentCardId
            }
            return filtered.map { decryptItem($0) }
        } catch {
            Log.error("HistoryRepository.fetchAll başarısız", error: error, category: .flow)
            return []
        }
    }

    func findByNonce(_ nonce: String) -> HistoryRecord? {
        try? db.read { db in
            try HistoryRecord.filter(Column("nonce") == nonce).fetchOne(db)
        }
    }

    // MARK: - Senkron (Aşama 5 — Android HistoryDao/HistoryRepository sync sorguları)

    /// Android `getAllHistorySnapshot`: silinmemiş tüm kayıtlar, timestamp DESC, title/description ÇÖZÜLMÜŞ.
    /// SyncManager yükleme adımı bunu kullanır (içeriği personId-AES-GCM ile yeniden şifrelemek için).
    /// `fetchAll`'dan farkı: cardId filtresi YOK (tüm kimliklerin kayıtları).
    func getAllHistorySnapshot() -> [HistoryRecord] {
        do {
            let raw = try db.read { db in
                try HistoryRecord
                    .filter(Column("isDeleted") == false)
                    .order(Column("timestamp").desc)
                    .fetchAll(db)
            }
            return raw.map { decryptItem($0) }
        } catch {
            Log.error("HistoryRepository.getAllHistorySnapshot başarısız", error: error, category: .flow)
            return []
        }
    }

    /// Android `getAllNonces`: yereldeki TÜM nonce'lar (silinmiş dahil).
    func getAllNonces() -> Set<String> {
        let list = (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT nonce FROM history")
        }) ?? []
        return Set(list)
    }

    /// Android `getDeletedNonces`: tombstone (isDeleted=1) nonce'lar.
    func getDeletedNonces() -> Set<String> {
        let list = (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT nonce FROM history WHERE isDeleted = 1")
        }) ?? []
        return Set(list)
    }

    /// Android `getAllPersonIds`: boş olmayan DISTINCT personId (bulut öğelerini çözmek için anahtarlar).
    func getAllPersonIds() -> [String] {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT personId FROM history WHERE personId != ''")
        }) ?? []
    }

    /// Android `getSentItems`: buluta gönderilmiş, silinmemiş kayıtlar (çözülmüş). SyncManager yalnız
    /// nonce kullanır ama Android paritesi için title/description çözülür.
    func getSentItems() -> [HistoryRecord] {
        let raw = (try? db.read { db in
            try HistoryRecord.filter(Column("isSent") == true && Column("isDeleted") == false).fetchAll(db)
        }) ?? []
        return raw.map { decryptItem($0) }
    }

    /// Android `getUnsentItems`: henüz gönderilmemiş kayıtlar (isDeleted dahil). title/description ŞİFRELİ
    /// bırakılır — çağıran yalnız `nonce`/`isDeleted` okur.
    func getUnsentItems() -> [HistoryRecord] {
        (try? db.read { db in
            try HistoryRecord.filter(Column("isSent") == false).fetchAll(db)
        }) ?? []
    }

    /// Android `markAsSent(nonces)`: kayıtları buluta gönderildi olarak işaretle.
    func markAsSent(_ nonces: [String]) {
        guard !nonces.isEmpty else { return }
        do {
            try db.write { db in
                for nonce in nonces {
                    try db.execute(sql: "UPDATE history SET isSent = 1 WHERE nonce = ?", arguments: [nonce])
                }
            }
        } catch {
            Log.error("HistoryRepository.markAsSent başarısız", error: error, category: .flow)
        }
    }

    /// Android `markAsDeletedByNonce`: tombstone (silinmiş + yeniden gönderilecek olarak işaretle).
    func markDeletedByNonce(_ nonce: String) {
        do {
            try db.write { db in
                try db.execute(sql: "UPDATE history SET isDeleted = 1, isSent = 0 WHERE nonce = ?", arguments: [nonce])
            }
        } catch {
            Log.error("HistoryRepository.markDeletedByNonce başarısız", error: error, category: .flow)
        }
    }

    /// Android `cleanupSyncedTombstones`: hem silinmiş hem (silinmesi) buluta gönderilmiş kayıtları kalıcı sil.
    func cleanupSyncedTombstones() {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM history WHERE isDeleted = 1 AND isSent = 1")
            }
        } catch {
            Log.error("HistoryRepository.cleanupSyncedTombstones başarısız", error: error, category: .flow)
        }
    }

    /// Android `insertCloudItem`: buluttan çözülmüş öğeyi yerele yaz. title/description yerel history key
    /// ile YENİDEN şifrelenir; `isSent = true`, yeni `id`.
    func insertCloudItem(_ item: HistoryRecord) {
        do {
            let encTitle = try encryptString(item.title)
            let encDesc = try encryptString(item.description)
            var rec = item
            rec.id = nil
            rec.title = encTitle
            rec.description = encDesc
            rec.isSent = true
            try db.write { db in try rec.insert(db) }
        } catch {
            Log.error("HistoryRepository.insertCloudItem başarısız", error: error, category: .flow)
        }
    }

    // MARK: - Şifreleme (Android encryptString/decryptString)

    private func encryptString(_ plain: String) throws -> String {
        guard let pub = historyPubKey else { throw KeychainKeyStoreError.keyNotFound }
        let (blob, aesKey) = try CryptoUtils.aesEncrypt(plain)
        let encKey = try CryptoUtils.rsaEncryptForKeystore(aesKey, publicKeyBase64: pub)
        let data = try JSONEncoder().encode(SecureContent(key: encKey, blob: blob))
        return String(decoding: data, as: UTF8.self)
    }

    private func decryptString(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONDecoder().decode(SecureContent.self, from: data) else {
            return "Encrypted"
        }
        do {
            let aesKey = try KeychainKeyStore.decryptWithHistoryKey(obj.key)
            return try CryptoUtils.aesDecrypt(blobBase64: obj.blob, keyBase64: aesKey)
        } catch {
            return "Encrypted"
        }
    }

    private func decryptItem(_ rec: HistoryRecord) -> HistoryRecord {
        var copy = rec
        copy.title = decryptString(rec.title)
        copy.description = decryptString(rec.description)
        return copy
    }
}
