import SwiftUI

/// Uygulama kökü — Wallet (home) + navigasyon. Android `MainActivity` (NavHost + ViewFlipper)
/// eşdeğeri: Wallet root, Settings/History push, Register/Login tam-ekran (fullScreenCover).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [Route] = []
    @State private var activeFlow: Flow?
    @State private var showDevMenu = false

    enum Route: Hashable { case settings, history }
    enum Flow: Int, Identifiable { case register, registerDemo, login; var id: Int { rawValue } }

    var body: some View {
        NavigationStack(path: $path) {
            WalletView(
                onAddCard: { activeFlow = .register },
                onDemo: { activeFlow = .registerDemo },
                onVerifyQr: { activeFlow = .login },
                onSettings: { path.append(.settings) },
                onHistory: { path.append(.history) },
                onDevMenu: (Config.appAttestEnvironment == .development) ? { showDevMenu = true } : nil
            )
            .navigationBarHidden(true)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .settings:
                    SettingsView(
                        onBack: { popPath() },
                        onHistory: { path.append(.history) }
                    )
                    .navigationBarHidden(true)
                case .history:
                    HistoryView(onBack: { popPath() })
                        .navigationBarHidden(true)
                }
            }
        }
        .tint(Theme.themePrimary)
        .fullScreenCover(item: $activeFlow, onDismiss: { appState.refresh() }) { flow in
            switch flow {
            case .register:
                RegisterFlowView(isDemo: false, onFinish: { activeFlow = nil })
            case .registerDemo:
                RegisterFlowView(isDemo: true, onFinish: { activeFlow = nil })
            case .login:
                LoginFlowView(onFinish: { activeFlow = nil })
            }
        }
        .sheet(isPresented: $showDevMenu) { DevMenuView() }
    }

    private func popPath() {
        if !path.isEmpty { path.removeLast() }
    }
}
