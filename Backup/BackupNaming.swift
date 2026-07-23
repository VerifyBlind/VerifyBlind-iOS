import Foundation

/// `.vfbackup` otomatik dosya adı — Android `backup/BackupNaming.kt` portu.
/// Biçim: `VerifyBlind-yyyyMMdd-HHmmss.vfbackup`. İki nokta (`:`) KULLANILMAZ (dosya sistemi/paylaşım).
enum BackupNaming {

    static let ext = ".vfbackup"

    static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "VerifyBlind-\(f.string(from: date))\(ext)"
    }
}
