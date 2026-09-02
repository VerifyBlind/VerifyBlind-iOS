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

    private static func load() -> [String: PartnerItem] {
        guard let data = d.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PartnerItem].self, from: data) else {
            return [:]
        }
        return map
    }
}
