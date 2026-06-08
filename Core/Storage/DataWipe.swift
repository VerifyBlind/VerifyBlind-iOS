import Foundation

/// "Verilerimi Sil" / Cüzdanı Sıfırla tam temizlik — Android `SettingsFragment.performFullReset` portu.
///
/// Tüm yerel kimlik/kripto/geçmiş/bulut izlerini siler. Android uygulamayı `Runtime.exit(0)` ile
/// yeniden başlatır; iOS'ta programatik çıkış App Store'da önerilmez → bunun yerine store'ları
/// boşaltıp `AppState.refresh()` ile boş cüzdana döneriz (çağıran sorumlu).
enum DataWipe {
    /// Sıralı, en güvenli → en hassas: GRDB geçmişi, ticket, SecureStore, Keychain anahtarları,
    /// UserDefaults, bulut yedek bağlantısı (+ buluttaki dosya). Hatalar yutulur (kısmî bozulmada
    /// olabildiğince çok şey temizlenmeli).
    static func wipeAll() async {
        // A. GRDB işlem geçmişi
        HistoryRepository.shared.deleteAll()

        // B. Ticket + UserDefaults (ticket/pubkey/expiry/kvkk/biometric/last_*/cloud)
        TicketStore.clear()
        AppPrefs.clearAll()

        // C. Hassas tanımlayıcılar (Keychain) + RSA anahtarları
        SecureStore.clear()
        KeychainKeyStore.deleteUserKey()
        KeychainKeyStore.deleteHistoryKey()

        // D. Bulut sağlayıcı bağlantısını kes + buluttaki yedek dosyasını sil
        await CloudBackupManager.disconnectAndDelete()

        Log.info("DataWipe.wipeAll tamamlandı", category: .flow)
    }
}
