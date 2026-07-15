import Foundation

/// Son geçerlilik tarihi biçimleyici — Android `WalletFragment.formatExpiryDate` birebir portu.
/// Girdi formatları denenir, çıktı `dd/MM/yyyy`. Boş → "—", ayrıştırılamazsa ham döner.
enum ExpiryFormatter {
    static func format(_ raw: String?) -> String {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return "—" }
        let inputs = ["yyMMdd", "yyyyMMdd", "dd/MM/yyyy", "dd.MM.yyyy", "yyyy-MM-dd"]
        let out = DateFormatter()
        out.dateFormat = "dd/MM/yyyy"
        out.locale = Locale(identifier: "en_US_POSIX")
        for fmt in inputs {
            let df = DateFormatter()
            df.dateFormat = fmt
            df.isLenient = false
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: r) { return out.string(from: d) }
        }
        return r
    }

    /// MRZ belge geçerlilik tarihi bugünden önceyse true — Android `WalletFragment.isExpired` portu.
    /// Parse edilemez/boşsa false (aktif kabul).
    static func isExpired(_ raw: String?) -> Bool {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return false }
        let inputs = ["yyMMdd", "yyyyMMdd", "dd/MM/yyyy", "dd.MM.yyyy", "yyyy-MM-dd"]
        for fmt in inputs {
            let df = DateFormatter()
            df.dateFormat = fmt
            df.isLenient = false
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: r) { return d < Date() }
        }
        return false
    }
}

/// PII maskeleme — Android `MainViewModel.mask` birebir portu (ilk 2 + yıldız + son 2).
enum Masker {
    static func mask(_ value: String?) -> String {
        guard let v = value, !v.isEmpty else { return "" }
        if v.count <= 4 { return "**\(v.count)**" }
        let stars = String(repeating: "*", count: v.count - 4)
        return "\(v.prefix(2))\(stars)\(v.suffix(2))"
    }
}
