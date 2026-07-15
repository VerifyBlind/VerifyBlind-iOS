import Foundation

/// iOS otomatik iCloud/iTunes **cihaz yedeği**nden dosya hariç tutma — Android `data_extraction_rules.xml`
/// + `backup_rules.xml`'in (`<exclude domain="database"/>` vb.) iOS karşılığı.
///
/// Neden (ZKP gereksinimi): Application Support altındaki GRDB veritabanı iCloud cihaz yedeğine
/// otomatik girer. `history` tablosundaki `personId` (= SHA256(TCKN)), `cardId`, `partnerId`,
/// `nonce`, `timestamp` kolonları **düz metin**tir. Yedek başka bir cihaza geri yüklenirse bu
/// pseudonim kimlik bağları cihaz dışına çıkmış olur. Yedek/geri yükleme YALNIZCA uygulamanın
/// kontrol ettiği sağlayıcılarla (Dropbox/Google Drive) yapılmalı — OS otomatik yedeğiyle DEĞİL.
/// Keychain tarafı zaten `ThisDeviceOnly` (SecureStore/KeychainKeyStore) → iCloud Keychain'e kapalı.
enum BackupExclusion {

    /// Verilen dosya/klasör URL'sini cihaz yedeğinden hariç tutar (`isExcludedFromBackup = true`).
    /// Dosya henüz yoksa sessizce başarısız olur (çağıran, dosya oluşturulduktan SONRA çağırmalı).
    /// Bir dizine uygulanırsa tüm alt ağaç yedekten hariç tutulur (Apple davranışı).
    @discardableResult
    static func exclude(_ url: URL) -> Bool {
        var url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.error("BackupExclusion: dosya yok, hariç tutulamadı — \(url.lastPathComponent)", category: .app)
            return false
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            Log.error("BackupExclusion.exclude başarısız — \(url.lastPathComponent)", error: error, category: .app)
            return false
        }
    }

    /// Teşhis/self-test: URL şu an yedekten hariç mi?
    static func isExcluded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]) else { return false }
        return values.isExcludedFromBackup ?? false
    }
}
