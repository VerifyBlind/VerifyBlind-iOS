import SwiftUI

/// Uygulama kök görünümü. Aşama 4'te gerçek akış (`RootView` → Wallet) ile değişti; dev self-test
/// içeriği `DevMenuView`'a taşındı (Wallet'ta logo'ya uzun bas ile dev'de açılır).
/// Biyometrik kilit açıksa cold-launch'ta `AppLockView` gösterilir.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = AppPrefs.biometricEnabled
    @State private var unlocking = false

    var body: some View {
        ZStack {
            RootView()
            if locked {
                AppLockView(onUnlock: { unlock() })
            }
        }
        .onAppear {
            if locked { unlock() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // Arka plana geçince kilitle (başka uygulamaya geçip dönünce de sorar).
                // SADECE .background — Face ID/NFC/kamera sistem UI'sı .inactive yapar, .background DEĞİL,
                // bu yüzden akış ortasında yanlış kilitlenme olmaz.
                if AppPrefs.biometricEnabled { locked = true }
            case .active:
                if locked { unlock() }
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
