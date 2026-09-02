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
        // A. Bulut sağlayıcı OAuth oturumlarını kapat. Manuel Yedekle/Geri Yükle modelinde sürekli
        // bağlantı YOK; buluttaki `.vfbackup` dosyalarına DOKUNULMAZ — onlar kullanıcının kendi bulut
        // hesabındaki bağımsız yedekleridir (Android `performFullReset` paritesi).
        DropboxProvider.shared.logout()
        GoogleDriveProvider.shared.logout()

        // B. GRDB işlem geçmişi
        try? HistoryRepository.shared.deleteAll()

        // C. Ticket + UserDefaults (ticket/pubkey/expiry/kvkk/biometric/last_*/cloud)
        TicketStore.clear()
        AppPrefs.clearAll()

        // C2. Hukuki metin kabulü. AYRI ÇAĞRI GEREKİYOR: `AppPrefs.clearAll()` sayılı bir anahtar
        // listesini siliyor ve kabul kaydı o listede değil — Android `user_prefs`'i tümüyle
        // sildiği için orada kendiliğinden gidiyordu. Bu ayrışma iOS pilotunun temiz kurulum turu
        // yazılınca ortaya çıktı: sıfırlamadan sonra hukuki kapı geri gelmiyordu.
        LegalTerms.clearAcceptance()

        // D. Hassas tanımlayıcılar (Keychain) + RSA anahtarları
        SecureStore.clear()
        KeychainKeyStore.deleteUserKey()
        KeychainKeyStore.deleteHistoryKey()

        Log.info("DataWipe.wipeAll tamamlandı", category: .flow)
    }
}
