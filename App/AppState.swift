import SwiftUI

/// Uygulama-seviyesi oturum durumu (Android `MainActivity`'nin signedTicketJson / SecureStore
/// durumuna karşılık). Store'lardan türetilir; akışlar bittiğinde `refresh()` ile tazelenir.
@MainActor
final class AppState: ObservableObject {
    @Published var hasCard: Bool
    @Published var expiryDate: String?
    @Published var currentCardId: String?
    /// Demo modu (kartsız cihaz testi). Dev'de açık; prod'da gizli. (Android `isDemoEnabled`.)
    @Published var demoEnabled: Bool = (Config.appAttestEnvironment == .development)

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
