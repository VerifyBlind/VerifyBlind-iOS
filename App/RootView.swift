import SwiftUI

/// Uygulama kökü — Wallet (home) + navigasyon. Android `MainActivity` (NavHost + ViewFlipper)
/// eşdeğeri: Wallet root, Settings/History push, Register/Login tam-ekran (fullScreenCover).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [Route] = []
    @State private var activeFlow: Flow?
    @State private var showDevMenu = false

    enum Route: Hashable { case settings, history, backup, help, security }
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
                        onHistory: { path.append(.history) },
                        onBackup: { path.append(.backup) },
                        onHelp: { path.append(.help) },
                        onSecurity: { path.append(.security) }
                    )
                    .navigationBarHidden(true)
                case .history:
                    HistoryView(onBack: { popPath() })
                        .navigationBarHidden(true)
                case .backup:
                    BackupSettingsView(onBack: { popPath() })
                        .navigationBarHidden(true)
                case .help:
                    HelpView(onBack: { popPath() })
                        .navigationBarHidden(true)
                case .security:
                    SecurityInfoView(onBack: { popPath() })
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
                // Deep-link varsa QR taramayı atlayıp doğrudan o URL ile başla.
                LoginFlowView(onFinish: { activeFlow = nil; appState.pendingVerifyURL = nil },
                              initialPayload: appState.pendingVerifyURL)
            }
        }
        .sheet(isPresented: $showDevMenu) { DevMenuView() }
        // Register/Login akışı açıkken otomatik kilidi bastır (NFC/kamera/Face ID mid-flow çakışmasın).
        .onChange(of: activeFlow) { flow in appState.suppressAutoLock = (flow != nil) }
        // Universal Link geldi → başka akış yoksa login'i aç (initialPayload fullScreenCover'da okunur).
        .onChange(of: appState.pendingVerifyURL) { url in
            if url != nil, activeFlow == nil { activeFlow = .login }
        }
    }

    private func popPath() {
        if !path.isEmpty { path.removeLast() }
    }
}
