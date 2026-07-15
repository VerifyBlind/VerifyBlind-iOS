import SwiftUI

// MARK: - Butonlar

/// Android `bg_vault_button` — birincil CTA (koyu lacivert gradient #002451→#1A3A6B, radius 16).
/// Wallet "Kimlik Kartı Ekle"/"QR ile Doğrula", register "Başla".
struct PrimaryGradientButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    /// İşlem sürerken: spinner göster + butonu devre dışı bırak (çift basmayı engeller).
    var loading: Bool = false
    var height: CGFloat = 60
    var fontSize: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Yükleme sırasında içeriği görünmez yap ama yerde tut → buton boyutu sabit kalır.
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 20, weight: .semibold))
                    }
                    Text(title).font(.system(size: fontSize, weight: .bold))
                }
                .opacity(loading ? 0 : 1)

                if loading {
                    ProgressView().tint(.white)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.buttonGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
            .opacity(enabled || loading ? 1 : 0.5)
        }
        .disabled(!enabled || loading)
    }
}

/// "Kimliği Kaldır" — kırmızı tehlike butonu (Android tint #B00020).
struct DangerButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        }
    }
}

/// "Nasıl Çalışır?" gibi ikincil bağlantı metni (blue-400).
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - Üst bar

/// Wallet/home üst barı (Android dark top app bar): tam-renkli logo + iki-tonlu
/// "Verify"(beyaz)+"Blind"(blue-400) wordmark + BETA amber pill + ayar dişlisi.
/// Koyu zemin status bar'ın arkasına uzanır (edge-to-edge).
struct TopAppBar: View {
    var onSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Image("logo")
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
            (Text("Verify").foregroundColor(.white)
                + Text("Blind").foregroundColor(Theme.secondary))
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .padding(.leading, 9)
            Text("BETA")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.accentOrange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.betaFill))
                .overlay(Capsule().stroke(Theme.betaStroke, lineWidth: 1))
                .padding(.leading, 9)
            Spacer()
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.outlineVariant)
                        .frame(width: 40, height: 40)
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        // Koyu zemin status bar'ın arkasına uzanır (edge-to-edge). Status bar ikonları BEYAZ:
        // RootView, yalnız cüzdan görünürken pencere arayüz stilini .dark yapar (updateStatusBarStyle).
        .background(Theme.bgDark.ignoresSafeArea(edges: .top))
    }
}

/// Geri butonlu başlık barı (History/Settings). Android header'ları.
struct NavTopBar: View {
    let title: String
    var titleColor: Color = Theme.primary
    var titleSize: CGFloat = 20
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.onSurface)
                    .frame(width: 40, height: 40)
            }
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundColor(titleColor)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Theme.topBarBg)
    }
}

// MARK: - Küçük bileşenler

/// Ayar/ikon dairesi (blue-soft / cyan-soft dolgu).
struct IconCircle: View {
    let systemName: String
    var fill: Color
    var tint: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.45))
                .foregroundColor(tint)
        }
    }
}

/// Yeşil "Doğrulandı / AKTİF" rozeti (Android `bg_badge_active`).
struct GreenBadge: View {
    let text: String
    var showCheck: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if showCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.badgeGreenText)
            }
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.badgeGreenText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.badgeGreenFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusBadge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusBadge)
                .stroke(Theme.badgeGreenStroke, lineWidth: 1)
        )
    }
}

/// Kart durumu rozeti — yeşil AKTİF / kırmızı SÜRESİ DOLDU (Android `tvActiveBadge`, dinamik).
struct StatusBadge: View {
    let text: String
    var expired: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(expired ? Theme.badgeRedText : Theme.badgeGreenText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(expired ? Theme.badgeRedFill : Theme.badgeGreenFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusBadge))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusBadge)
                    .stroke(expired ? Theme.badgeRedStroke : Theme.badgeGreenStroke, lineWidth: 1)
            )
    }
}

/// Beyaz yüzey kart (1dp border, radius 16) — Android `bg_settings_card`.
struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .stroke(Theme.outlineVariant, lineWidth: 1)
            )
    }
}

/// Bottom sheet sürükleme tutamacı (Android drag handle 36×4).
struct SheetHandle: View {
    var body: some View {
        Capsule()
            .fill(Color(hex: "#C4C6D0"))
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }
}

// MARK: - Stepper (Kart ekleme 4 adım)

/// Android `layoutStepperRow` — 4 daire + bağlantı çizgileri. `current` 1-tabanlı aktif adım.
struct StepperHeader: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                let stepNo = idx + 1
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(stepNo <= current ? Theme.stepperActive : Theme.stepperInactive)
                            .frame(width: 28, height: 28)
                        if stepNo < current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(stepNo)")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                    }
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(width: 56)

                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(Theme.stepperInactive)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 20) // daire merkezine hizala (label yüksekliği telafisi)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }
}
