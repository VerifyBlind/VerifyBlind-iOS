import SwiftUI

/// Uygulama kök görünümü. Aşama 4'te gerçek akış (`RootView` → Wallet) ile değişti; dev self-test
/// içeriği `DevMenuView`'a taşındı (Wallet'ta logo'ya uzun bas ile dev'de açılır).
/// Biyometrik kilit açıksa cold-launch'ta `AppLockView` gösterilir.
struct ContentView: View {
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
