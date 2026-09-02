import Foundation
import GRDB

/// GRDB veritabanı sahibi — Android Room `AppDatabase` eşdeğeri. `history` tablosu (v1 migration).
final class AppDatabase {
    static let shared = makeShared()

    let dbQueue: DatabaseQueue

    /// Disk üzerindeki DB dosyası (self-test/teşhis için). Bellek-içi DB'de nil.
    private(set) static var fileURL: URL?

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static func makeShared() -> AppDatabase {
        do {
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
            let dbURL = dir.appendingPathComponent("verifyblind.sqlite")
            let queue = try DatabaseQueue(path: dbURL.path)   // dosyayı oluşturur
            // ZKP: DB'yi iCloud/iTunes cihaz yedeğinden hariç tut (personId/cardId düz metin kolonlar).
            // DatabaseQueue WAL kullanmaz → tek .sqlite dosyası; -journal yalnız yazma sırasında geçici.
            // Android tarafındaki data_extraction_rules.xml karşılığı.
            BackupExclusion.exclude(dbURL)
            fileURL = dbURL
            Log.info("AppDatabase açıldı: \(dbURL.lastPathComponent) (yedekten hariç: \(BackupExclusion.isExcluded(dbURL)))", category: .app)
            return try AppDatabase(queue)
        } catch {
            Log.error("AppDatabase açılamadı — in-memory fallback", error: error, category: .app)
            // Uygulamayı çökertme: bellek-içi DB ile devam (history kalıcı olmaz ama akış kırılmaz).
            // swiftlint:disable:next force_try
            return try! AppDatabase(DatabaseQueue())
        }
    }

    /// `internal` (private DEĞİL): `HistoryDeleteTests` geçişleri `upTo:` ile adım adım koşturup
    /// v3'ün eski satırlara ne yaptığını doğruluyor.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_history") { db in
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("description", .text).notNull()
                t.column("actionType", .integer).notNull().defaults(to: 0)
                t.column("status", .integer).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("transactionId", .text)
                t.column("nonce", .text).notNull().indexed()
                t.column("personId", .text).notNull().defaults(to: "")
                t.column("cardId", .text).notNull().defaults(to: "")
                t.column("partnerId", .text)
                t.column("isSent", .boolean).notNull().defaults(to: false)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("revokeTime", .integer)
            }
        }
        // v2: işlem geçmişine şifreli `deviceName` kolonu (Android Room v7→v8 paritesi). Veri kaybı yok.
        migrator.registerMigration("v2_deviceName") { db in
            try db.alter(table: "history") { t in
                t.add(column: "deviceName", .text).notNull().defaults(to: "")
            }
        }
        // v3: tombstone KALINTILARINI kalıcı sil. Manuel Yedekle/Geri Yükle modelinde silme sert
        // DELETE'tir (Android `HistoryDao.deleteById` paritesi) ama iOS bir süre `isDeleted = 1`
        // yazmaya devam etti. O satırlar listede GÖRÜNMEZ, buna karşılık nonce'ları
        // `getAllNonces()`'ta durur → yedekten geri yükleme onları sonsuza dek "zaten var" sayıp
        // atlar ("0 eklendi, 1 atlandı", geçmiş boş kalır). Kullanıcı bu kayıtları zaten silmişti;
        // satırı kalıcı kaldırmak hem doğru davranış hem de nonce'u serbest bırakır.
        // `isDeleted` SÜTUNU şemada FİZİKSEL kalır (Android'de de öyle) — artık hiç yazılmaz.
        migrator.registerMigration("v3_purge_tombstones") { db in
            try db.execute(sql: "DELETE FROM history WHERE isDeleted = 1")
        }
        return migrator
    }
}
