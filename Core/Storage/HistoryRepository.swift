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
            // İşlemi yapan cihazın adını burada (yerel işlem anında) yakala ve şifrele.
            let encDevice = try encryptString(DeviceInfo.marketingName())
            var rec = HistoryRecord(
                id: nil, title: encTitle, description: encDesc,
                actionType: actionType.rawValue, status: status, timestamp: timestamp,
                transactionId: nil, nonce: nonce, personId: personId, cardId: cardId,
                partnerId: partnerId, deviceName: encDevice, isSent: false, isDeleted: false, revokeTime: nil
            )
            try db.write { db in try rec.insert(db) }
            Log.info("History kaydı eklendi (tür \(actionType.rawValue))", category: .flow)
        } catch {
            Log.error("HistoryRepository.insert başarısız", error: error, category: .flow)
        }
    }

    /// Android `HistoryDao.deleteById`: tek kaydı **SERT** siler. Tombstone (`isDeleted = 1`) YASAK —
    /// tabloda kalan satır listede görünmez ama nonce'u `getAllNonces()`'ta durur ve o kayıt yedekten
    /// bir daha geri yüklenemez ("0 eklendi, 1 atlandı"). Manuel modelde silme yerelde kalıcıdır.
    func deleteById(_ id: Int64) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM history WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.error("HistoryRepository.deleteById başarısız", error: error, category: .flow)
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

    /// Android `HistoryDao.deleteAll`. Hata YUTULMAZ: çağıran "Tüm geçmiş silindi" derken silinmemiş
    /// olabileceğini bilmeli (eski sürüm hatayı loglayıp yine de başarı mesajı gösteriyordu).
    func deleteAll() throws {
        try db.write { db in _ = try HistoryRecord.deleteAll(db) }
    }

    /// Bir karta ait TÜM geçmişi SERT siler (kart silinirken "işlem geçmişimi de sil" seçilince).
    /// Manuel Yedekle/Geri Yükle modelinde silme yerelde kalıcıdır (tombstone yok) — Android
    /// `deleteByCardId` paritesi.
    func deleteByCardId(_ cardId: String) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM history WHERE cardId = ?", arguments: [cardId])
            }
        } catch {
            Log.error("HistoryRepository.deleteByCardId başarısız", error: error, category: .flow)
        }
    }

    // MARK: - Okuma

    /// Android `allHistory` + `HistoryFragment` cardId filtresi: current cardId'e ait (veya cardId'si
    /// boş genel) kayıtlar, timestamp DESC, title/description çözülmüş.
    ///
    /// Filtre Android'le BİREBİR: `item.cardId.isEmpty() || item.cardId == (currentCardId ?: "")`.
    /// Kayıtlı kart YOKKEN (nil) yalnız cardId'si boş genel kayıtlar görünür — kaldırılan kartın
    /// geçmişi listede kalmaz. Kayıtlar SİLİNMEZ, yalnız gizlenir; `getAllHistorySnapshot`'ta
    /// (yani yedek dosyasında) yer almaya devam ederler.
    func fetchAll(currentCardId: String?) -> [HistoryRecord] {
        do {
            let raw = try db.read { db in
                try HistoryRecord
                    .filter(Column("isDeleted") == false)
                    .order(Column("timestamp").desc)
                    .fetchAll(db)
            }
            let filtered = raw.filter { rec in
                rec.cardId.isEmpty || rec.cardId == (currentCardId ?? "")
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

    // MARK: - Yedekleme (Android HistoryDao snapshot/nonce sorguları)

    /// Android `getAllHistorySnapshot`: tüm kayıtlar, timestamp DESC, title/description ÇÖZÜLMÜŞ.
    /// Yedek dosyasının içeriği bundan üretilir. `fetchAll`'dan farkı: cardId filtresi YOK
    /// (tüm kimliklerin kayıtları). `isDeleted` filtresi Android'le birebir korunur — sütun şemada
    /// fiziksel olarak duruyor ama artık YAZILMIYOR, dolayısıyla daima 0.
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

    /// Android `getAllNonces`: yereldeki TÜM nonce'lar — içe-aktarma tekilleştirmesi için.
    /// Silme sert olduğu için burada dönen her nonce gerçekten DURAN bir kayda aittir.
    func getAllNonces() -> Set<String> {
        let list = (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT nonce FROM history")
        }) ?? []
        return Set(list)
    }

    /// `.vfbackup` geri-yüklemesinden gelen kaydı ekler (Android `insertBackupRecord`). Düz metin
    /// title/description/deviceName yerel history key ile YENİDEN şifrelenir; yeni id. Çağıran
    /// (BackupManager) nonce tekilleştirmesini önceden yapmış olmalı.
    ///
    /// Hata YUTULMAZ (Android paritesi): eskiden yutuluyordu ve `BackupManager` "eklendi" sayısını
    /// insert DENEMESİ üzerinden verdiği için hiçbir şey yazılmadan "1 eklendi" gösterilebiliyordu.
    func insertBackupRecord(_ record: BackupRecord) throws {
        var rec = BackupMapper.toEntity(record)
        rec.title = try encryptString(rec.title)
        rec.description = try encryptString(rec.description)
        rec.deviceName = rec.deviceName.isEmpty ? "" : try encryptString(rec.deviceName)
        try db.write { db in try rec.insert(db) }
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
        // Eski kayıtlarda deviceName boş → çözmeye çalışma, boş bırak.
        copy.deviceName = rec.deviceName.isEmpty ? "" : decryptString(rec.deviceName)
        return copy
    }
}
