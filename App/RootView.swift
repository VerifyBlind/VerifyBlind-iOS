import SwiftUI

/// Uygulama kökü — Wallet (home) + navigasyon. Android `MainActivity` (NavHost + ViewFlipper)
/// eşdeğeri: Wallet root, Settings/History push, Register/Login tam-ekran (fullScreenCover).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [Route] = []
    @State private var activeFlow: Flow?
    @State private var showDevMenu = false
    @State private var showDemoPasswordAlert = false
    @State private var demoPasswordInput = ""

    enum Route: Hashable { case settings, history, backup, help, security }
    enum Flow: Int, Identifiable { case register, registerDemo, login; var id: Int { rawValue } }

    var body: some View {
        NavigationStack(path: $path) {
            WalletView(
                onAddCard: { activeFlow = .register },
                onDemo: { triggerDemo() },
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
        // Demo şifresi giriş dialogu (Android showDemoPasswordDialog paritesi).
        .alert(L.t("demo_mode_title"), isPresented: $showDemoPasswordAlert) {
            SecureField(L.t("demo_hint"), text: $demoPasswordInput)
            Button(L.t("common_ok")) {
                let entered = demoPasswordInput
                demoPasswordInput = ""
                if entered == (appState.serverDemoPassword ?? "") {
                    activeFlow = .registerDemo
                }
            }
            Button(L.t("btn_cancel"), role: .cancel) { demoPasswordInput = "" }
        } message: {
            Text(L.t("demo_mode_enter_code"))
        }
        // Zorunlu güncelleme: engelleyici tam-ekran overlay (Android ForceUpdate event paritesi).
        .overlay {
            if appState.needsForceUpdate {
                forceUpdateOverlay
            }
        }
    }

    private var forceUpdateOverlay: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(Theme.themePrimary)
                Text(L.t("force_update_title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.onSurface)
                Text(L.t("force_update_message"))
                    .font(.system(size: 15))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(action: openAppStore) {
                    Text(L.t("force_update_btn"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.themePrimary, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private func openAppStore() {
        let raw = appState.storeUrl ?? "https://apps.apple.com/app/id6743770042"
        if let url = URL(string: raw) {
            UIApplication.shared.open(url)
        }
    }

    private func triggerDemo() {
        let serverPwd = appState.serverDemoPassword ?? ""
        if serverPwd.isEmpty {
            activeFlow = .registerDemo
        } else {
            showDemoPasswordAlert = true
        }
    }

    private func popPath() {
        if !path.isEmpty { path.removeLast() }
    }
}
