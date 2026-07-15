import SwiftUI

/// Uygulama-seviyesi oturum durumu (Android `MainActivity`'nin signedTicketJson / SecureStore
/// durumuna karşılık). Store'lardan türetilir; akışlar bittiğinde `refresh()` ile tazelenir.
@MainActor
final class AppState: ObservableObject {
    @Published var hasCard: Bool
    @Published var expiryDate: String?
    @Published var currentCardId: String?
    /// Demo modu (kartsız cihaz testi). Cihaz sürümü, admin panelden tanımlanan iOS demo sürümüyle
    /// birebir eşleşirse açılır (`loadConfig`'te belirlenir). Android `demoEnabled` paritesi.
    @Published var demoEnabled: Bool = false
    /// Register/Login tam-ekran akışı açıkken otomatik biyometrik kilidi bastır — NFC/kamera/Face ID
    /// sistem UI'sı akış ortasında .background tetikleyip sahte kilit/döngü yaratmasın.
    @Published var suppressAutoLock = false
    /// Universal Link ile gelen doğrulama URL'i (`https://app.verifyblind.com/request?nonce=...`).
    /// Set edilince RootView login akışını QR taramadan, bu URL ile başlatır. Akış bitince temizlenir.
    @Published var pendingVerifyURL: String?

    /// Minimum iOS sürümü — zorunlu güncelleme kontrolü için (Android `minimumVersion`).
    @Published var minimumIosVersion: String? = nil
    /// App Store URL (force-update ekranında kullanılır).
    @Published var storeUrl: String? = nil

    init() {
        hasCard = TicketStore.hasTicket
        expiryDate = AppPrefs.expiryDate
        currentCardId = SecureStore.getCardId()
    }

    func refresh() {
        hasCard = TicketStore.hasTicket
        expiryDate = AppPrefs.expiryDate
        currentCardId = SecureStore.getCardId()
    }

    /// Sunucu app-config'ini çeker; zorunlu güncelleme + demo butonu görünürlüğünü günceller.
    /// Android `MainViewModel.fetchAppConfig` paritesi.
    func loadConfig() async {
        do {
            let cfg = try await VerifyAPI.shared.appConfig()
            minimumIosVersion = cfg.minimumIosVersion
            storeUrl = cfg.storeUrl
            // Demo butonu: cihaz sürümü admin tanımlı iOS demo sürümüyle birebir eşleşirse görünür.
            let demoVersion = cfg.demoVersionIos ?? ""
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            demoEnabled = !demoVersion.isEmpty && demoVersion == current
        } catch {
            Log.warning("AppConfig yüklenemedi: \(error)", category: .app)
        }
    }

    /// Mevcut sürüm sunucunun belirlediği minimumdan eskiyse true (Android `isVersionOlder`).
    var needsForceUpdate: Bool {
        guard let minVersion = minimumIosVersion, !minVersion.isEmpty,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return false
        }
        let cur = current.split(separator: ".").compactMap { Int($0) }
        let min = minVersion.split(separator: ".").compactMap { Int($0) }
        for i in 0..<Swift.max(cur.count, min.count) {
            let c = i < cur.count ? cur[i] : 0
            let m = i < min.count ? min[i] : 0
            if c < m { return true }
            if c > m { return false }
        }
        return false
    }
}
