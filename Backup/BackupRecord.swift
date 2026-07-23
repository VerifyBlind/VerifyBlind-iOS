import Foundation

/// `.vfbackup` dosyasındaki tek işlem kaydı — kendi içinde bağımsız (aynı dosyada çok kişi/çok kart).
/// Android `backup/BackupRecord` (BackupModels.kt) BİREBİR portu; JSON anahtarları eşleşmek zorunda.
///
/// `personId` YALNIZ görüntü filtresi içindir (kripto rolü yok). `title`/`description`/`deviceName`
/// burada DÜZ metindir (repository'den çözülmüş); dosya şifreliyse tüm dosyayla korunur.
struct BackupRecord: Codable, Equatable {
    var nonce: String
    var personId: String
    var cardId: String
    var partnerId: String?
    var title: String
    var description: String
    var actionType: Int
    var status: Int
    var timestamp: Int64
    var transactionId: String?
    var deviceName: String
}

/// `BackupFile.inspect` çıktısı — dosyayı DB'ye eklemeden liste/onay ekranında gösterilir.
struct BackupInfo {
    let schemaVersion: Int
    let fileId: String
    let createdAt: String
    let encrypted: Bool
    /// Şifresiz dosyada işlem sayısı; şifreli dosyada paroladan önce bilinemez → nil.
    let recordCount: Int?
}

/// Şifreli `.vfbackup` için parola durumları.
enum BackupPasswordError: Error {
    case needsPassword
    case wrongPassword
    case malformed
}
