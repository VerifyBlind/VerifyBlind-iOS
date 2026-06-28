import SwiftUI

/// Uygulama kök görünümü. Aşama 4'te gerçek akış (`RootView` → Wallet) ile değişti; dev self-test
/// içeriği `DevMenuView`'a taşındı (Wallet'ta logo'ya uzun bas ile dev'de açılır).
/// Biyometrik kilit açıksa cold-launch'ta `AppLockView` gösterilir.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = AppPrefs.biometricEnabled
    @State private var unlocking = false
    /// Cold-launch açılış splash'ı (Android `SplashActivity` paritesi). Yalnız ilk açılışta gösterilir,
    /// arka plandan dönüşte tekrar gösterilmez.
    @State private var showSplash = true

    var body: some View {
        ZStack {
            RootView()
            if locked {
                AppLockView(onUnlock: { unlock() })
            }
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1) // kilit ekranının da üstünde — önce marka, sonra Face ID
            }
        }
        .task {
            // Splash'ı min süre göster (Android MIN_SPLASH_MS paritesi), sonra fade-out.
            try? await Task.sleep(nanoseconds: SplashView.minDurationNanos)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
                // Biyometrik kilidi splash bittikten SONRA aç — Face ID sistem prompt'u splash'ın
                // üstüne çıkıp 2.2sn boyunca görünmesin.
                if locked { unlock() }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // Arka plana geçince kilitle (başka uygulamaya geçip dönünce de sorar).
                // ⚠️ Register/Login akışı açıkken (suppressAutoLock) KİLİTLEME — NFC/kamera/Face ID
                // sistem UI'sı akış ortasında .background tetikleyip sahte kilit/döngü yaratıyordu.
                if AppPrefs.biometricEnabled && !appState.suppressAutoLock { locked = true }
            case .active:
                // Splash hâlâ görünürken unlock'u tetikleme; splash bitişi (.task) hallediyor.
                if locked && !showSplash { unlock() }
            default:
                break
            }
        }
    }

    private func unlock() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            defer { unlocking = false }
            do {
                try await BiometricGate.authenticate(reason: L.t("app_lock_desc"))
                locked = false
            } catch {
                Log.info("Uygulama kilidi açma iptal/başarısız (kilitli kalır)", category: .flow)
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
