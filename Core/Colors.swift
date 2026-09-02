import SwiftUI

extension Color {
    // Fill / CTA — blue-600 in both modes (use as button background, not text on dark)
    static let brandPrimary = Color("BrandPrimary")

    // Adaptive semantic tokens (light / dark resolved from asset catalog)
    static let brandBackground = Color("BrandBackground")
    static let brandSurface = Color("BrandSurface")
    static let brandForeground = Color("BrandForeground")
    static let brandMuted = Color("BrandMuted")
    static let brandBorder = Color("BrandBorder")

    // Status
    static let brandSuccess = Color("BrandSuccess")
    static let brandWarning = Color("BrandWarning")
    static let brandDanger = Color("BrandDanger")

    // Link / accent text on dark bg — blue-400 in dark, blue-700 in light
    static let brandLink = Color("BrandLink")
}
