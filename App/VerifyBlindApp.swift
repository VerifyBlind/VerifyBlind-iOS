import SwiftUI

@main
struct VerifyBlindApp: App {
    @StateObject private var appState = AppState()

    init() {
        LogBootstrap.start()
        Log.info("Uygulama başlatıldı — version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")", category: .app)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light) // Android light-mode paritesi
        }
    }
}
