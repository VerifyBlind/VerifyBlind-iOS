import SwiftUI

/// Uygulama kilidi ekranı — Android `app_lock` (biyometrik açılış kilidi). Ayarlar'da Biyometrik
/// Kilit açıksa cold-launch'ta gösterilir; Face ID/passcode ile açılır.
struct AppLockView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("logo").resizable().scaledToFit().frame(width: 88, height: 88)
                Image(systemName: "lock.fill").font(.system(size: 36)).foregroundColor(Theme.secondary)
                Text(L.t("app_lock_title"))
                    .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                Text(L.t("app_lock_desc"))
                    .font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button(action: onUnlock) {
                    Text(L.t("btn_unlock"))
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme.themePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 48).padding(.top, 12)
            }
        }
    }
}
