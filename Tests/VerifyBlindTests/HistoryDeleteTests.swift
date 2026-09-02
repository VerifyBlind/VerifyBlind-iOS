import XCTest
import GRDB
@testable import VerifyBlind

/// Silme semantiği regresyonları — manuel Yedekle/Geri Yükle modelinde silme **SERTtir**
/// (tombstone YOK; Android `HistoryDao.deleteById` / `deleteAll` paritesi, spec
/// `2026-07-23-manual-backup-restore-design.md` satır 41 + 229).
///
/// Neden test: tombstone (`isDeleted = 1`) kalan satır listede GÖRÜNMEZ ama nonce'u
/// `getAllNonces()`'ta durur → `BackupMapper.selectNewRecords` onu "yerelde zaten var" sayar ve
/// yedekten geri yükleme kaydı sonsuza dek atlar ("0 eklendi, 1 atlandı", geçmiş boş kalır).
///
/// Şifreleme (Keychain history key) bilerek kapsam dışı: satırlar doğrudan GRDB ile yazılır, böylece
/// test simülatörde Keychain'e bağımlı olmadan koşar.
final class HistoryDeleteTests: XCTestCase {

    private func makeRepo() throws -> (AppDatabase, HistoryRepository) {
        let appDb = try AppDatabase(DatabaseQueue())   // bellek-içi, migrate edilmiş
        return (appDb, HistoryRepository(db: appDb.dbQueue))
    }

    @discardableResult
    private func insertRaw(_ dbQueue: DatabaseQueue, nonce: String, cardId: String = "") throws -> Int64 {
        var rec = HistoryRecord(
            id: nil, title: "başlık", description: "açıklama",
            actionType: HistoryAction.registration.rawValue, status: 1,
            timestamp: 1_700_000_000_000, transactionId: nil, nonce: nonce,
            personId: "p1", cardId: cardId, partnerId: nil, deviceName: "",
            isSent: false, isDeleted: false, revokeTime: nil
        )
        try dbQueue.write { db in try rec.insert(db) }
        return rec.id!
    }

    private func backupRecord(nonce: String) -> BackupRecord {
        BackupRecord(
            nonce: nonce, personId: "p1", cardId: "", partnerId: nil,
            title: "başlık", description: "açıklama",
            actionType: HistoryAction.registration.rawValue, status: 1,
            timestamp: 1_700_000_000_000, transactionId: nil, deviceName: ""
        )
    }

    // MARK: - Tek satır silme (sola kaydır)

    func testDeleteByIdRemovesRowEntirely() throws {
        let (appDb, repo) = try makeRepo()
        let id = try insertRaw(appDb.dbQueue, nonce: "N1")

        repo.deleteById(id)

        XCTAssertTrue(repo.getAllNonces().isEmpty, "Sert silme sonrası nonce tabloda KALMAMALI (tombstone yok)")
        XCTAssertNil(repo.findByNonce("N1"), "Satır tablodan tamamen gitmeli")
        XCTAssertTrue(repo.fetchAll(currentCardId: nil).isEmpty)
    }

    /// Bildirilen arıza: kaydı sil → yedekten geri yükle → "0 eklendi, 1 atlandı", geçmiş boş.
    func testDeletedRecordCanBeRestoredFromBackup() throws {
        let (appDb, repo) = try makeRepo()
        let id = try insertRaw(appDb.dbQueue, nonce: "N1")
        let backup = [backupRecord(nonce: "N1")]

        repo.deleteById(id)

        let toAdd = BackupMapper.selectNewRecords(backup, localNonces: repo.getAllNonces())
        XCTAssertEqual(toAdd.count, 1, "Silinen kayıt yedekten geri YÜKLENEBİLMELİ (atlanmamalı)")
    }

    /// Duran (silinmemiş) kayıt hâlâ atlanmalı — additive + idempotent sözleşmesi bozulmasın.
    func testExistingRecordIsStillSkipped() throws {
        let (appDb, repo) = try makeRepo()
        try insertRaw(appDb.dbQueue, nonce: "N1")

        let toAdd = BackupMapper.selectNewRecords([backupRecord(nonce: "N1")], localNonces: repo.getAllNonces())
        XCTAssertTrue(toAdd.isEmpty, "Yerelde duran nonce ikinci kez eklenmemeli")
    }

    // MARK: - Tümünü Sil

    func testDeleteAllClearsTableIncludingLegacyTombstones() throws {
        let (appDb, repo) = try makeRepo()
        try insertRaw(appDb.dbQueue, nonce: "N1")
        try appDb.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO history (title, description, actionType, status, timestamp, nonce,
                                     personId, cardId, deviceName, isSent, isDeleted)
                VALUES ('t', 'd', 1, 1, 1, 'ESKI_TOMBSTONE', '', '', '', 0, 1)
                """)
        }

        try repo.deleteAll()

        XCTAssertTrue(repo.getAllNonces().isEmpty, "Tümünü Sil tabloyu tamamen boşaltmalı")
    }

    // MARK: - Şema geçişi (v3)

    /// Eski sürümlerin bıraktığı `isDeleted = 1` satırları geçişte kalıcı silinmeli; aksi hâlde o
    /// nonce'lar geri yüklemeyi sonsuza dek bloklar (kullanıcı kaydı zaten silmişti).
    func testMigrationPurgesLegacyTombstones() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2_deviceName")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO history (title, description, actionType, status, timestamp, nonce,
                                     personId, cardId, deviceName, isSent, isDeleted)
                VALUES ('t', 'd', 1, 1, 1, 'HAYALET', '', '', '', 0, 1),
                       ('t', 'd', 1, 1, 2, 'CANLI',   '', '', '', 0, 0)
                """)
        }

        try AppDatabase.migrator.migrate(queue)

        let nonces = try queue.read { db in try String.fetchAll(db, sql: "SELECT nonce FROM history") }
        XCTAssertEqual(nonces, ["CANLI"], "Tombstone satırları geçişte silinmeli, canlı satır kalmalı")
    }
}
