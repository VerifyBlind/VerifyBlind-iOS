import SwiftUI

/// Uygulama kökü — Wallet (home) + navigasyon. Android `MainActivity` (NavHost + ViewFlipper)
/// eşdeğeri: Wallet root, Settings/History push, Register/Login tam-ekran (fullScreenCover).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [Route] = []
    @State private var activeFlow: Flow?
    @State private var showDevMenu = false

    enum Route: Hashable { case settings, history, backup, help, faq, security }

    enum Flow: Hashable, Identifiable {
        case register
        case registerDemo
        /// `payload` = deep-link URL; nil ise kullanıcı QR taramak için elle açtı.
        case login(payload: String?)

        /// Kimlik payload'u İÇERİR. Böylece yeni bir deep-link geldiğinde id DEĞİŞİR ve SwiftUI
        /// cover içeriğini yeniden kurar. Sabit id (eski `rawValue`) ile `.login` zaten açıkken
        /// gelen deep-link'te view kimliği korunuyor, `LoginFlowView`'un `@StateObject` vm'i
        /// yeniden yaratılmıyor ve `initialPayload` sessizce düşüyordu → kamera açık kalıp
        /// hiçbir şey olmuyordu.
        var id: String {
            switch self {
            case .register:           return "register"
            case .registerDemo:       return "registerDemo"
            case .login(let payload): return "login:\(payload ?? "")"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            WalletView(
                onAddCard: { activeFlow = .register },
                onDemo: { triggerDemo() },
                onVerifyQr: { activeFlow = .login(payload: nil) },
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
                        onFaq: { path.append(.faq) },
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
                case .faq:
                    FaqWebView(onBack: { popPath() })
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
            case .login(let payload):
                // Deep-link varsa QR taramayı atlayıp doğrudan o URL ile başla.
                LoginFlowView(onFinish: { activeFlow = nil; appState.pendingVerifyURL = nil },
                              onToast: { appState.showToast($0) },
                              initialPayload: payload)
                    // Payload değişince TAZE view kimliği (→ taze `@StateObject` vm). Cover'ın
                    // kendi kimliği zaten değişiyor; bu, SwiftUI sunumu geri dönüştürse bile
                    // eski kameranın/akışın devralınmamasını garantiler.
                    .id(flow.id)
            }
        }
        .sheet(isPresented: $showDevMenu) { DevMenuView() }
        // Register/Login akışı açıkken otomatik kilidi bastır (NFC/kamera/Face ID mid-flow çakışmasın).
        .onChange(of: activeFlow) { flow in
            appState.suppressAutoLock = (flow != nil)
            updateStatusBarStyle()
        }
        .onChange(of: path) { _ in updateStatusBarStyle() }
        .onAppear { updateStatusBarStyle() }
        // Universal Link geldi → login'i aç. Başka bir akış (kayıt / QR kamera) açıksa deeplink onu
        // YERİNDE preempt eder (Item 3a — Android `handleIntent` paritesi): tek atama yeter, çünkü
        // `Flow.login` kimliği payload'u içeriyor. Kapat-bekle-yeniden-aç YOK; eski view'ın
        // `onDisappear`'ı kamerayı durdurur ve terminal olmayan nonce'u iptal eder
        // (`LoginViewModel.onFlowDismissed` → Android `cancelQrNonce(prev)` karşılığı).
        .onChange(of: appState.pendingVerifyURL) { url in
            guard let url else { return }
            activeFlow = .login(payload: url)
        }
        // Zorunlu güncelleme: engelleyici tam-ekran overlay (Android ForceUpdate event paritesi).
        .overlay {
            if appState.needsForceUpdate {
                forceUpdateOverlay
            }
        }
        // Geçici toast (Android Toast paritesi) — alt orta capsule, ~2sn.
        .overlay(alignment: .bottom) {
            if let msg = appState.toastMessage {
                Text(msg)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toastMessage)
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
        // Şifre yok: buton yalnızca cihaz sürümü admin tanımlı demo sürümüyle eşleşince (demoEnabled)
        // görünür, dolayısıyla görünürlüğü zaten yetkilendirmedir.
        activeFlow = .registerDemo
    }

    private func popPath() {
        if !path.isEmpty { path.removeLast() }
    }

    /// Cüzdan (NavigationStack kökü, akış yok) görünürken pencereyi .dark yapar → koyu status
    /// bar + BEYAZ ikon. Diğer ekranlar (Settings/History push, register/login cover) açık
    /// zeminli → .light (siyah ikon okunur). Theme renkleri sabit hex olduğu için görünüm
    /// DEĞİŞMEZ; yalnız status bar ikonları etkilenir. App Info.plist'te light-locked
    /// olduğundan per-ekran status bar kontrolünün güvenilir yolu budur.
    private func updateStatusBarStyle() {
        let style: UIUserInterfaceStyle = (path.isEmpty && activeFlow == nil) ? .dark : .light
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.overrideUserInterfaceStyle = style }
    }
}
