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
            if let blockMsg = appState.attestationBlockMessage {
                AttestationBlockView(message: blockMsg) { await appState.runAttestationGate() }
                    .transition(.opacity)
                    .zIndex(2) // splash + kilit ekranının da üstünde — kapatılamaz launch-gate
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.attestationBlockMessage)
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
                // ⚠️ Register/Login/bulut akışı açıkken (suppressAutoLock) KİLİTLEME — NFC/kamera/
                // Face ID sistem UI'sı akış ortasında .background tetikleyip sahte kilit yaratıyordu.
                let willLock = AppPrefs.biometricEnabled && !appState.suppressAutoLock
                // Bu satır TEŞHİS İÇİN kalıcı: Google OAuth ekranının açılır açılmaz kaybolması üç
                // ayrı düzeltmeye direndi ve her seferinde "kilit devreye girdi mi?" sorusuna
                // kayıtla değil tahminle cevap verdik.
                Log.info("scene→background: kilitlenecek=\(willLock) bastırma=\(appState.suppressAutoLock)",
                         category: .flow)
                if willLock { locked = true }
            case .active:
                // Splash hâlâ görünürken unlock'u tetikleme; splash bitişi (.task) hallediyor.
                let willUnlock = locked && !showSplash
                Log.info("scene→active: kilitli=\(locked) unlock çağrılacak=\(willUnlock)", category: .flow)
                if willUnlock { unlock() }
                // BLOKLUYSA attestation kapısını yeniden koş.
                //
                // Kapı yalnız `.task` ile, yani SOĞUK AÇILIŞTA koşuyordu ve blok mesajı bellekte
                // duruyordu. Sunucu düzeldikten sonra bile kullanıcı için çıkış yolu, iOS'un süreci
                // gerçekten öldürmesine kalıyordu: uygulamayı kapatıp açmak çoğu zaman yalnız askıya
                // alıp geri getiriyor ve blok ekranı olduğu gibi kalıyor. 2026-08-25'te kullanıcı
                // bu yüzden uygulamayı SİLİP yeniden kurmak zorunda kaldı — kabul edilemez bir
                // kurtarma yolu. Artık arka plana atıp geri gelmek yetiyor.
                //
                // Yalnız blokluyken koşar: sağlıklı durumda her öne gelişte handshake atmanın
                // anlamı yok, kimlik akışları attestation'ı zaten koşulsuz zorluyor.
                if appState.attestationBlockMessage != nil {
                    Task { await appState.runAttestationGate() }
                }
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

/// Launch-time enclave attestation engeli — kapatılamaz tam-ekran (Android `finishAffinity` paritesi).
///
/// Kurtuluş: ekran kapatılamaz ama KİLİTLİ DEĞİL. Uygulama öne her geldiğinde kapı yeniden koşar
/// (bkz. `scenePhase == .active`), yani sunucu düzelince kullanıcı arka plana atıp dönerek kurtulur.
/// Eskiden yalnız soğuk açılışta koşuyordu ve iOS süreci öldürmediği sürece blok kalıcı oluyordu.
private struct AttestationBlockView: View {
    let message: String
    /// Kapıyı yeniden çalıştırır. Sunucu düzeldiyse blok kalkar.
    let onRetry: () async -> Void

    @State private var retrying = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 64))
                    .foregroundColor(Theme.themePrimary)
                Text(L.t("error_attestation_title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.onSurface)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // AÇIK bir kurtuluş yolu. Önce bunu uygulamanın öne gelişine bağlamıştık; cihazda
                // tetiklenmedi ve kullanıcı uygulamayı SİLİP yeniden kurmak zorunda kaldı
                // (2026-08-26). Neden tetiklenmediğini cihaz olmadan bulamadım, o yüzden kurtarmayı
                // artık görünmez bir yaşam-döngüsü olayına değil, kullanıcının bastığı bir düğmeye
                // bağlıyorum: sessizce çalışmamak diye bir ihtimali kalmıyor.
                Button {
                    guard !retrying else { return }
                    retrying = true
                    Task {
                        await onRetry()
                        retrying = false
                    }
                } label: {
                    if retrying {
                        ProgressView().tint(Theme.themePrimary)
                    } else {
                        Text(L.t("attestation_retry"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .disabled(retrying)
                .frame(minWidth: 160, minHeight: 44)
                .foregroundColor(Theme.themePrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.themePrimary, lineWidth: 1.5)
                )
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
