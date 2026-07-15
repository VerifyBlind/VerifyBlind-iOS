import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// Android `colors.xml` birebir parite için hex'ten Color. "#RRGGBB" / "#AARRGGBB" / "RRGGBB".
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var rgba: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgba)

        let r, g, b, a: Double
        switch s.count {
        case 8: // AARRGGBB (Android sırası)
            a = Double((rgba & 0xFF00_0000) >> 24) / 255
            r = Double((rgba & 0x00FF_0000) >> 16) / 255
            g = Double((rgba & 0x0000_FF00) >> 8) / 255
            b = Double(rgba & 0x0000_00FF) / 255
        default: // RRGGBB
            a = 1
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - VerifyBlind Tasarım Token'ları (Android res/values/colors.xml birebir)
//
// Android light-mode-only; iOS de light'a kilitlenir (Info.plist UIUserInterfaceStyle=Light).
// Mevcut adaptif `Core/Colors.swift` (asset-catalog) parite için KULLANILMAZ — token'lar buradan gelir.

enum Theme {
    // Backgrounds / surfaces
    static let background      = Color(hex: "#F8FAFC")   // sv_background (slate-50)
    static let surface         = Color(hex: "#FFFFFF")   // sv_surface
    static let surfaceLow       = Color(hex: "#F1F5F9")  // sv_surface_low (slate-100)
    static let surfaceHigh     = Color(hex: "#F1F5F9")   // sv_surface_high (slate-100)
    static let surfaceHighest  = Color(hex: "#E2E8F0")   // sv_surface_highest (slate-200)
    static let bgDark          = Color(hex: "#0F172A")   // bg_dark (slate-900)
    static let topBarBg        = Color(hex: "#CCF7F9FC") // app bar yarı saydam (80% alpha)

    // Brand / primary
    static let primary         = Color(hex: "#1E3A8A")   // sv_primary (blue-900) — başlık/heading
    static let primaryContainer = Color(hex: "#1E3A8A")  // sv_primary_container
    static let themePrimary    = Color(hex: "#2563EB")   // theme_primary / accent_blue (blue-600) — CTA dolgu
    static let primaryVariant  = Color(hex: "#1D4ED8")   // primary_variant (blue-700) — pressed
    static let secondary       = Color(hex: "#60A5FA")   // sv_secondary (blue-400) — koyu zeminde metin/ikon (Kural 8)
    static let secondaryContainer = Color(hex: "#93C5FD") // sv_secondary_container (blue-300)

    // Text / ink
    static let onSurface       = Color(hex: "#0F172A")   // sv_on_surface (slate-900)
    static let onSurfaceVariant = Color(hex: "#475569")  // sv_on_surface_variant (slate-600)
    static let onPrimary       = Color(hex: "#FFFFFF")   // sv_on_primary
    static let textOnDark      = Color(hex: "#FFFFFF")   // text_primary
    static let textSecondaryOnDark = Color(hex: "#94A3B8") // slate-400

    // Borders
    static let outlineVariant  = Color(hex: "#CBD5E1")   // sv_outline_variant (slate-300)
    static let cardStroke      = Color(hex: "#334155")   // card_stroke (slate-700)

    // Accents
    static let accentCyan      = Color(hex: "#22D3EE")   // accent_cyan (cyan-400)
    static let chipCyan        = Color(hex: "#0891B2")   // chip_cyan (cyan-600)

    // Status
    static let success         = Color(hex: "#10B981")   // success / nfc_success_green
    static let error           = Color(hex: "#EF4444")   // error
    static let danger          = Color(hex: "#B00020")   // "Kimliği Kaldır" buton kırmızısı

    // Icon-circle soft fills (settings çipleri)
    static let blueSoft        = Color(hex: "#DBEAFE")   // bg_circle_blue_soft
    static let cyanSoft        = Color(hex: "#CFFAFE")   // bg_circle_cyan_soft

    // Stepper
    static let stepperActive   = Color(hex: "#2563EB")
    static let stepperInactive = Color(hex: "#CBD5E1")

    // History item ikon daireleri (bg_circle_green/gray/red) — beyaz glyph
    static let circleGreen = Color(hex: "#2E7D32")  // bg_circle_green (Green 800)
    static let circleGray  = Color(hex: "#404040")  // bg_circle_gray
    static let circleRed   = Color(hex: "#C62828")  // bg_circle_red (Red 800)

    // Consent logo / delete dialog ikon kabı (bg_lock_icon_circle) — yuvarlatılmış DİKDÖRTGEN
    static let lockIconBg     = Color(hex: "#112038")
    static let lockIconStroke = Color(hex: "#1A3A6A")

    // Birincil CTA — wallet/register "vault" butonu (bg_vault_button): #002451→#1A3A6B, 45°
    static let buttonGradient = LinearGradient(
        colors: [Color(hex: "#002451"), Color(hex: "#1A3A6B")],
        startPoint: .bottomLeading, endPoint: .topTrailing
    )

    // Consent onay butonu (bg_btn_blue_gradient): blue-900 → blue-600, yatay
    static let consentButtonGradient = LinearGradient(
        colors: [Color(hex: "#1E3A8A"), Color(hex: "#2563EB")],
        startPoint: .leading, endPoint: .trailing
    )

    // NFC halka rengi (bg_nfc_ring_blue stroke)
    static let nfcRing = Color(hex: "#54A3FD")
    // Telefon mockup gövde/kenar (bg_phone_mockup_new)
    static let phoneBody = Color(hex: "#1A3A6B")
    static let phoneEdge = Color(hex: "#001B3F")

    // Wallet kartı (bg_wallet_card_redesign): #0D448C → #0B2B5C
    static let walletCardGradient = LinearGradient(
        colors: [Color(hex: "#0D448C"), Color(hex: "#0B2B5C")],
        startPoint: .leading, endPoint: .trailing
    )
    static let walletCardStroke  = Color(hex: "#1A61B8")
    static let walletCardType    = Color(hex: "#8AABCC")  // "Doğrulanmış Kimlik"
    static let walletExpiryLabel = Color(hex: "#5A88C4")  // "SON GEÇERLİLİK TARİHİ"
    static let badgeGreenText    = Color(hex: "#00C853")  // Doğrulandı / AKTİF
    static let badgeGreenFill    = Color(hex: "#1A00C853") // bg_badge_active dolgu
    static let badgeGreenStroke  = Color(hex: "#3300C853")

    // Köşe yarıçapları (Android dp ≈ pt)
    static let radiusButton: CGFloat = 16   // vault CTA (Add/QR/Başla)
    static let radiusCard: CGFloat = 16
    static let radiusBadge: CGFloat = 8
}
