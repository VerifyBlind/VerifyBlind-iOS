import Foundation

/// Partner önbelleği — Android `data/PartnerManager` (SharedPreferences JSON) iOS portu (UserDefaults).
struct PartnerItem: Codable {
    let partnerId: String
    let name: String
    let logoUrl: String
    let logoBase64: String?
    let timestamp: Int64
}

enum PartnerManager {
    private static let key = "partner_cache"
    private static let d = UserDefaults.standard

    static func save(_ item: PartnerItem) {
        var all = load()
        all[item.partnerId] = item
        if let data = try? JSONEncoder().encode(all) {
            d.set(data, forKey: key)
        }
    }

    static func get(_ partnerId: String) -> PartnerItem? {
        load()[partnerId]
    }

    /// Tüm önbellekli partnerler — bulut yedek/geri yükleme (Aşama 5) enumerate eder.
    static func all() -> [String: PartnerItem] {
        load()
    }

    /// "Verilerimi Sil" — önbelleği tümüyle kaldırır (Android `performFullReset`'in `partner_cache` +
    /// `VerifyBlind_Partners` temizliği paritesi).
    ///
    /// Tam temizlikten SONRA burada kalan kayıtlar, kullanıcının hangi partnerlerle doğrulama
    /// yaptığını (ad + logo) cihazda tutmaya devam ediyordu — `DataWipe` her izi sildiğini
    /// söylerken (parite denetimi 2026-09-03, O-3).
    static func clear() {
        d.removeObject(forKey: key)
    }

    private static func load() -> [String: PartnerItem] {
        guard let data = d.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PartnerItem].self, from: data) else {
            return [:]
        }
        return map
    }
}
