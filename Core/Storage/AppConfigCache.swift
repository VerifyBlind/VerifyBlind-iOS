import Foundation

/// Android `util/AppConfigCache.kt`'nin portu — `/api/public/app-config`'ten gelen, arka plan
/// bileşenlerinin de görmesi gereken ayarların kalıcı önbelleği.
///
/// Neden gerekli: config'i `AppState.loadConfig` çekiyor ama `SyncManager` arka planda, AppState'e
/// erişmeden çalışıyor; ayrıca bellek-içi bir alan process ölümünden sağ çıkmaz.
///
/// `UserDefaults` yeterli: burada sır YOK, yalnız bir davranış bayrağı (Keychain gereksiz).
///
/// Varsayılanlar bilinçli olarak GÜVENLİ TARAFTA: config hiç okunamadıysa yedek v1 yazılır →
/// eski istemcilerle uyum korunur, veri kaybı yolu kapalı kalır.
enum AppConfigCache {

    private static let keyBackupFormatV2 = "backup_format_v2"

    /// app-config her çekildiğinde çağrılır.
    static func setBackupFormatV2Enabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keyBackupFormatV2)
    }

    /// Bulut yedeği v2 (KEK/DEK) formatında YAZ. Varsayılan FALSE.
    ///
    /// Sunucu bunu ancak zorunlu güncelleme tamamlandıktan sonra açar: v1-only bir istemci v2
    /// dosyasını okuyamadığı halde geri yazarken `wraps` alanını DÜŞÜRÜR → DEK kaybolur → tüm
    /// geçmiş kurtarılamaz hale gelir.
    static func isBackupFormatV2Enabled() -> Bool {
        UserDefaults.standard.bool(forKey: keyBackupFormatV2)
    }
}
