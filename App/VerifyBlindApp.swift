import SwiftUI

@main
struct VerifyBlindApp: App {
    init() {
        LogBootstrap.start()
        Log.info("Uygulama başlatıldı — version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")", category: .app)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
