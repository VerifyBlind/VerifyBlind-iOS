import SwiftUI

/// Uygulama-seviyesi oturum durumu (Android `MainActivity`'nin signedTicketJson / SecureStore
/// durumuna karşılık). Store'lardan türetilir; akışlar bittiğinde `refresh()` ile tazelenir.
@MainActor
final class AppState: ObservableObject {
    @Published var hasCard: Bool
    @Published var expiryDate: String?
    @Published var currentCardId: String?
    /// Demo modu (kartsız cihaz testi). Dev VE TestFlight'ta açık (reviewer + harici testçiler kartsız
    /// denesin diye); gerçek App Store production build'inde gizli. (Android `isDemoEnabled`.)
    @Published var demoEnabled: Bool = (Config.appAttestEnvironment == .development) || Config.isTestFlight
    /// Register/Login tam-ekran akışı açıkken otomatik biyometrik kilidi bastır — NFC/kamera/Face ID
    /// sistem UI'sı akış ortasında .background tetikleyip sahte kilit/döngü yaratmasın.
    @Published var suppressAutoLock = false
    /// Universal Link ile gelen doğrulama URL'i (`https://app.verifyblind.com/request?nonce=...`).
    /// Set edilince RootView login akışını QR taramadan, bu URL ile başlatır. Akış bitince temizlenir.
    @Published var pendingVerifyURL: String?

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
}
