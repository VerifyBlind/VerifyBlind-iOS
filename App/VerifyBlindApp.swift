import SwiftUI
import UserNotifications

@main
struct VerifyBlindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    init() {
        LogBootstrap.start()
        Log.info("Uygulama başlatıldı — version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")", category: .app)
        BackupBootstrap.configure()   // Dropbox/Google SDK + önceki oturum + sağlayıcı kaydı (Aşama 5)
        requestPushPermission()
    }

    /// Kullanıcıdan push bildirimi izni ister; onaylanırsa sistem APNs token'ı AppDelegate'e iletir.
    private func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { Log.warning("Push izni hatası: \(error.localizedDescription)", category: .app); return }
            guard granted else { Log.info("Push bildirimi izni reddedildi.", category: .app); return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light) // Android light-mode paritesi
                .task { await appState.loadConfig() }
                .onOpenURL { url in
                    // Bulut yedekleme OAuth redirect'leri (Dropbox db-<key>://, Google reversed-client-id).
                    if BackupBootstrap.handleOpenURL(url) { return }
                    handleVerifyURL(url)   // özel şema (nadir) → verify deep-link
                }
                // Universal Link (https://app.verifyblind.com/request?...) → verify akışı.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { handleVerifyURL(url) }
                }
        }
    }

    /// `app.verifyblind.com` verify deep-link'ini AppState'e koyar; RootView login akışını başlatır.
    private func handleVerifyURL(_ url: URL) {
        guard url.host == "app.verifyblind.com" else { return }
        Log.info("Verify deep-link alındı", category: .flow)
        appState.pendingVerifyURL = url.absoluteString
    }
}
