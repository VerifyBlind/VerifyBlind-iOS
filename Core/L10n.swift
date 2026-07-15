import Foundation

/// Lokalizasyon yardımcısı — Android `getString(R.string.x)` eşdeğeri.
/// Değerler `{tr,en}.lproj/Localizable.strings`'ten gelir; cihaz diline göre seçilir.
enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    /// Yardım içeriği ayrı tablodan (`Help.strings`) — Android `strings_help.xml` paritesi.
    /// Format ARGÜMANSIZ: içerik `%65` gibi düz `%` içerir, `String(format:)` KULLANILMAZ.
    static func help(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Help", comment: "")
    }
}
