import Foundation

/// Bulut yedek JSON şeması — Android `SyncManager` `CloudPayload`/`CloudHistoryItem`/`InnerPayload`
/// ile **birebir** (çapraz platform: Android↔iOS geri yükleme). Dosya: `verifyblind_backup.json`.
///
/// Şifreleme: her geçmiş öğesi `personId` türevli AES-GCM ile şifreli (`CryptoUtils.aesGcmEncrypt`,
/// key = SHA256(personId)). personId aynı kart yeniden kaydedilince yeniden türetilir → telefon
/// sıfırlansa bile aynı kişi kaydını çözebilir; çözemediği (başka kişiye ait) öğeleri aynen korur.
///
/// JSON anahtar uyumu: Swift `JSONEncoder` varsayılan anahtarları property adıyla aynıdır ve nil
/// optional'ları ATLAR (Gson'un null'ları atlama davranışıyla eşleşir). Property adları Android Gson
/// alan adlarıyla (camelCase) birebir tutulmuştur.

/// Üst seviye yedek payload'ı. (Android `SyncManager.CloudPayload`.)
struct CloudPayload: Codable {
    var history: [CloudHistoryItem]?
    /// Partnerler artık geçmiş öğeleri gibi `personId`-AES-GCM ile şifreli (Android `partnersEnc`).
    /// Eski düz-metin `partners` haritası kaldırıldı; eski dosyalardaki o anahtar decode'da yok sayılır.
    var partnersEnc: [EncPartner]?
}

/// Şifreli partner girdisi — Android `SyncManager.EncPartner`. `enc` = AES-GCM(personId)( BackupPartnerItem
/// JSON ), `iv` ayrı. Çözülünce elde edilen düz metin = `BackupPartnerItem` (id/name/logoUrl/logoBase64/
/// lastUpdated) — Android `PartnerItem` alan adlarıyla birebir (çapraz platform).
struct EncPartner: Codable {
    let enc: String
    let iv: String
}

/// Şifreli bulut geçmiş öğesi. `enc` = AES-GCM(personId) ciphertext‖tag (base64), `iv` ayrı.
/// (Android `SyncManager.CloudHistoryItem`.)
struct CloudHistoryItem: Codable {
    let enc: String
    let iv: String
    let actionType: Int
    let status: Int
    var transactionId: String?
}

/// `enc` çözülünce elde edilen düz metin yapısı. (Android `SyncManager.InnerPayload`.)
struct InnerPayload: Codable {
    let title: String
    let description: String
    let cardId: String
    let personId: String
    let timestamp: Int64
    let nonce: String
    var partnerId: String?
}

/// Bulut partner kaydı — Android `data/PartnerItem` (Gson) anahtarları: `id, name, logoUrl,
/// logoBase64, lastUpdated`. iOS yerel `PartnerItem` farklı alan adları (`partnerId`, `timestamp`)
/// kullandığı için çapraz-platform uyumu adına AYRI Codable + dönüşüm.
struct BackupPartnerItem: Codable {
    let id: String
    let name: String
    var logoUrl: String?
    var logoBase64: String?
    let lastUpdated: Int64

    /// iOS yerel PartnerItem → bulut formatı.
    init(from item: PartnerItem) {
        self.id = item.partnerId
        self.name = item.name
        self.logoUrl = item.logoUrl
        self.logoBase64 = item.logoBase64
        self.lastUpdated = item.timestamp
    }

    /// Bulut formatı → iOS yerel PartnerItem.
    func toPartnerItem() -> PartnerItem {
        PartnerItem(partnerId: id, name: name, logoUrl: logoUrl ?? "",
                    logoBase64: logoBase64, timestamp: lastUpdated)
    }
}
