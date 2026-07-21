import Foundation

/// Bulut yedek JSON şeması — Android `SyncManager` `CloudPayload`/`CloudHistoryItem`/`InnerPayload`
/// ile **birebir** (çapraz platform: Android↔iOS geri yükleme). Dosya: `verifyblind_backup.json`.
///
/// Şifreleme iki formatlı (bkz. `BackupFormat`):
///   **v1** (`v` alanı YOK): her geçmiş öğesi DOĞRUDAN `personId` türevli AES-GCM ile şifreli
///   (`CryptoUtils.aesGcmEncrypt`, key = SHA256(personId)).
///   **v2** (`v == 2`): her öğe rastgele bir DEK ile şifreli; DEK, `KEK = SHA256(personId)` ile
///   sarılıp `wraps[]` içinde tutulur. Aynı DEK birden çok KEK ile sarılabildiği için kimlik tabanı
///   değişince (TCKN → PIN) yalnız yeni bir wrap eklenir; geçmiş ASLA yeniden şifrelenmez.
///
/// Her iki formatta da personId aynı kart yeniden kaydedilince yeniden türetilir → telefon
/// sıfırlansa bile aynı kişi kaydını çözebilir; çözemediği (başka kişiye ait) öğeleri aynen korur.
///
/// JSON anahtar uyumu: Swift `JSONEncoder` varsayılan anahtarları property adıyla aynıdır ve nil
/// optional'ları ATLAR (Gson'un null'ları atlama davranışıyla eşleşir). Property adları Android Gson
/// alan adlarıyla (camelCase) birebir tutulmuştur.

/// Üst seviye yedek payload'ı. (Android `BackupFormat.CloudPayloadV2`.)
///
/// v1 ve v2'yi TEK model okur:
///   `v == nil` → v1 (eski): geçmiş DOĞRUDAN `SHA256(personId)` ile şifreli.
///   `v == 2`   → v2 (yeni): geçmiş rastgele DEK ile şifreli; DEK `wraps[]` içinde KEK ile sarılı.
///
/// YAZMA NOTU: v1 yazarken `v` ve `wraps` nil bırakılır; `JSONEncoder` nil optional'ları ATLAR →
/// çıktı birebir eski v1 şeması olur (Gson'un null atlama davranışıyla eşleşir). Bu, zorunlu
/// güncelleme tamamlanana kadar eski istemcilerle uyumun garantisidir.
struct CloudPayload: Codable {
    var v: Int?
    var wraps: [DekWrap]?
    var history: [CloudHistoryItem]?
    /// Partnerler geçmiş öğeleri gibi şifreli (Android `partnersEnc`). Eski düz-metin `partners`
    /// haritası kaldırıldı; eski dosyalardaki o anahtar decode'da yok sayılır.
    var partnersEnc: [EncPartner]?
}

/// Sarılmış DEK — Android `BackupFormat.DekWrap` ile BİREBİR (`enc`, `iv`, `pinUuid`).
/// `enc` = AES-GCM(KEK)( base64(ham 32 baytlık DEK) ), `iv` ayrı.
///
/// `pinUuid == nil` → TCKN kimliği: personId karttan (login) gelir, kullanıcıya PIN sorulmaz.
/// `pinUuid != nil` → PIN kimliği: kullanıcıya PIN sorulur, `(pin, pinUuid)` sunucuda person_id'ye
/// türetilir. UUID sır DEĞİLDİR — per-user salt'tır; düz metin durması tasarım gereğidir.
struct DekWrap: Codable {
    let enc: String
    let iv: String
    var pinUuid: String?
}

/// Şifreli partner girdisi — Android `SyncManager.EncPartner`. `enc` = AES-GCM( BackupPartnerItem JSON ),
/// `iv` ayrı; anahtar geçmiş öğeleriyle AYNI (v2'de DEK, v1'de `SHA256(personId)`). Çözülünce elde
/// edilen düz metin = `BackupPartnerItem` (id/name/logoUrl/logoBase64/lastUpdated) — Android
/// `PartnerItem` alan adlarıyla birebir (çapraz platform).
struct EncPartner: Codable {
    let enc: String
    let iv: String
}

/// Şifreli bulut geçmiş öğesi. `enc` = ciphertext‖tag (base64), `iv` ayrı.
/// **Anahtar formata göre değişir:** v2'de `wraps[]`'ten açılan ham DEK, v1'de `SHA256(personId)`
/// (bkz. `CloudPayload` şema notu). (Android `SyncManager.CloudHistoryItem`.)
struct CloudHistoryItem: Codable {
    let enc: String
    let iv: String
    let actionType: Int
    let status: Int
    var transactionId: String?
}

/// `enc` çözülünce elde edilen düz metin yapısı. (Android `SyncManager.InnerPayload`.)
/// `deviceName` opsiyonel: eski yedeklerde alan yok → decode'da nil (okurken `?? ""`). Android'de de
/// nullable (`String? = null`) — çapraz-platform lenient decode paritesi.
struct InnerPayload: Codable {
    let title: String
    let description: String
    let cardId: String
    let personId: String
    let timestamp: Int64
    let nonce: String
    var partnerId: String?
    var deviceName: String?
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
