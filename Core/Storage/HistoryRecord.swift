import Foundation
import GRDB

/// Android `data/HistoryEntity.kt` `HistoryAction` paritesi.
enum HistoryAction: Int {
    case generic = 0
    case registration = 1     // Kimlik eklendi
    case sharedIdentity = 2   // Doğrulama yapıldı (partner login) — "Kimlik Paylaşıldı" DEĞİL
    case deletedCard = 3      // Kimlik kaldırıldı
    case restoredBackup = 4
    case revokedIdentity = 5  // Rıza geri çekildi
}

/// Android Room `HistoryEntity` (`history_table`) GRDB portu. `title`/`description` şifreli
/// (SecureContent JSON); display'de `HistoryRepository` çözer. `timestamp`/`revokeTime` epoch ms.
struct HistoryRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var title: String
    var description: String
    var actionType: Int
    var status: Int
    var timestamp: Int64
    var transactionId: String?
    var nonce: String
    var personId: String
    var cardId: String
    var partnerId: String?
    /// İşlemi yapan cihazın pazarlama adı (ör. "iPhone 14 Pro"). title/description gibi SecureContent
    /// ile şifreli saklanır; okurken çözülür. Eski kayıtlarda boş. Default → memberwise init'te opsiyonel.
    var deviceName: String = ""
    var isSent: Bool
    var isDeleted: Bool
    var revokeTime: Int64?

    static let databaseTableName = "history"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var action: HistoryAction { HistoryAction(rawValue: actionType) ?? .generic }
    var isRevoked: Bool { revokeTime != nil }
}
