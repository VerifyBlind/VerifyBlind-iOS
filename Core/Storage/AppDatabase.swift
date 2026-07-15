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
            // Bkz [[project_ios_backup_zkp_hardening]] — Android data_extraction_rules.xml karşılığı.
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

    private static var migrator: DatabaseMigrator {
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
        return migrator
    }
}
