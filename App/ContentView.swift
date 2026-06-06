import SwiftUI

/// Uygulama kök görünümü. Aşama 4'te gerçek akış (`RootView` → Wallet) ile değişti; dev self-test
/// içeriği `DevMenuView`'a taşındı (Wallet'ta logo'ya uzun bas ile dev'de açılır).
struct ContentView: View {
    var body: some View {
        RootView()
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
