import SwiftUI

/// Açılış splash'ı — Android `SplashActivity` + `activity_splash.xml` birebir paritesi:
/// koyu zemin (bg_dark), logoya merkezli 3 katmanlı nefes alan radyal glow, iki renkli
/// "VerifyBlind" başlığı (Verify=beyaz, Blind=sv_secondary) ve tagline. Android'de bu ekran
/// ayrıca Integrity/install-source kontrolü yapıyor; iOS'ta bunların karşılığı App Attest ile
/// akış içinde olduğundan splash yalnız görseldir (sabit minimum görünür süre).
/// Gösterim/dismiss `ContentView`'da yönetilir; min süre = Android `MIN_SPLASH_MS` (2200ms).
struct SplashView: View {
    /// Android `MIN_SPLASH_MS` (2.2 sn) paritesi — splash'ın minimum görünür kalma süresi.
    static let minDurationNanos: UInt64 = 2_200_000_000

    // Fade-in opaklıkları (Android AlphaAnimation eşdeğeri)
    @State private var logoOpacity = 0.0
    @State private var outerOpacity = 0.0
    @State private var midOpacity = 0.0
    @State private var innerOpacity = 0.0
    @State private var titleOpacity = 0.0
    @State private var taglineOpacity = 0.0

    // Sonsuz "nefes alma" ölçekleri (Android ScaleAnimation REVERSE/INFINITE eşdeğeri)
    @State private var logoScale = 0.92
    @State private var outerScale = 1.0
    @State private var midScale = 1.05
    @State private var innerScale = 0.95

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()

            VStack(spacing: 0) {
                // Logo + arkasında merkezlenmiş glow halkaları (layout'u etkilemez, taşar).
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130, height: 130)
                    .opacity(logoOpacity)
                    .scaleEffect(logoScale)
                    .background(glowStack)

                // Başlık — Android: marginTop 24dp
                (Text("Verify").foregroundColor(.white)
                    + Text("Blind").foregroundColor(Theme.secondary))
                    .font(.system(size: 34, weight: .medium))
                    .tracking(1.3) // letterSpacing 0.04em ≈ 1.36pt
                    .opacity(titleOpacity)
                    .padding(.top, 24)

                // Tagline — Android: marginTop 8dp, #668596AD, letterSpacing 0.02em
                Text(L.t("splash_tagline"))
                    .font(.system(size: 14))
                    .tracking(0.3)
                    .foregroundColor(Color(hex: "#668596AD"))
                    .opacity(taglineOpacity)
                    .padding(.top, 8)
            }
            .offset(y: -40) // Android vertical bias 0.40 — merkezin hafif üstü
        }
        .onAppear(perform: startAnimations)
    }

    /// Glow halkaları (Android bg_splash_glow_{outer,mid,inner}.xml — radial oval gradient).
    private var glowStack: some View {
        ZStack {
            glow(size: 420, color: Color(hex: "#1A1A6EE8"))
                .opacity(outerOpacity).scaleEffect(outerScale)
            glow(size: 270, color: Color(hex: "#330080EE"))
                .opacity(midOpacity).scaleEffect(midScale)
            glow(size: 175, color: Color(hex: "#558BBFFF"))
                .opacity(innerOpacity).scaleEffect(innerScale)
        }
    }

    private func glow(size: CGFloat, color: Color) -> some View {
        RadialGradient(
            gradient: Gradient(colors: [color, color.opacity(0)]),
            center: .center, startRadius: 0, endRadius: size / 2
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func startAnimations() {
        // Fade-in'ler (Android AlphaAnimation duration/startOffset eşdeğeri)
        withAnimation(.easeOut(duration: 0.6)) { innerOpacity = 1 }
        withAnimation(.easeOut(duration: 0.8)) { logoOpacity = 1; midOpacity = 1 }
        withAnimation(.easeOut(duration: 1.0)) { outerOpacity = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.4)) { titleOpacity = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.6)) { taglineOpacity = 1 }

        // Sonsuz nefes alma (autoreverses — Android REVERSE; süre = tek geçiş = Android duration)
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            logoScale = 1.08
        }
        withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
            outerScale = 1.18
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true).delay(0.2)) {
            midScale = 1.14
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true).delay(0.1)) {
            innerScale = 1.08
        }
    }
}

#Preview {
    SplashView()
}
