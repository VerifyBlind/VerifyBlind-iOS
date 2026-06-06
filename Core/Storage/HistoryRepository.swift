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
