import SwiftUI

@main
struct VerifyBlindApp: App {
    @StateObject private var appState = AppState()

    init() {
        LogBootstrap.start()
        Log.info("Uygulama başlatıldı — version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")", category: .app)
        BackupBootstrap.configure()   // Dropbox/Google SDK + önceki oturum + sağlayıcı kaydı (Aşama 5)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light) // Android light-mode paritesi
                .onOpenURL { url in
                    // Bulut yedekleme OAuth redirect'leri (Dropbox db-<key>://, Google reversed-client-id).
                    BackupBootstrap.handleOpenURL(url)
                }
        }
    }
}
