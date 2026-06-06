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
}
