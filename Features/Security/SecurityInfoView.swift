import SwiftUI

/// Sistem Güvenliği — Android `SecurityInfoFragment` + `fragment_security_info.xml` portu (Aşama 6).
/// Attestation teşhisini `AppPrefs` last_* bayraklarından okur (handshake + App Attest sonucu Part B
/// tarafından doldurulur): PCR0, doğrulama durumu (üçlü), son kontrol zamanı, kaynak kodu linki.
struct SecurityInfoView: View {
    let onBack: () -> Void

    private let pcr0 = AppPrefs.lastPcr0 ?? "N/A"
    private let isVerified = AppPrefs.lastHardwareVerified
    private let isMock = AppPrefs.lastIsMock
    private let lastTime = AppPrefs.lastAttestationTime

    // Android renk sabitleri (0xFF...): verified yeşil, guard mavi; mock turuncu; risk kırmızı.
    private let greenColor  = Color(hex: "#4CAF50")
    private let blueColor   = Color(hex: "#2563EB")
    private let orangeColor = Color(hex: "#FF9800")
    private let redColor    = Color(hex: "#F44336")

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_security_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L.t("security_details_label"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .padding(.top, 4)

                    statusCard
                    pcr0Card
                    publisherCard

                    PrimaryGradientButton(title: L.t("security_view_source"), systemImage: "chevron.left.forwardslash.chevron.right",
                                          height: 52, fontSize: 15) {
                        openSource()
                    }
                    .padding(.top, 4)

                    Text(L.t("security_footer"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Kartlar

    private var statusCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("security_verify_label"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.onSurfaceVariant)

                Text(statusText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(statusColor)

                Text(guardText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(guardColor)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").font(.system(size: 12)).foregroundColor(Theme.chipCyan)
                    Text(L.t("security_aws_label")).font(.system(size: 11)).foregroundColor(Theme.onSurfaceVariant)
                }
                .padding(.top, 4)

                Text(lastCheckText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }

    private var pcr0Card: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("security_pcr0_label")).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                Text(pcr0)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.themePrimary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(L.t("security_pcr0_desc")).font(.system(size: 11)).foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }

    private var publisherCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("security_publisher_label")).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                Text(L.t("security_publisher_desc")).font(.system(size: 11)).foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }

    // MARK: - Durum mantığı (Android paritesi)

    private var statusText: String {
        if isVerified { return L.t("security_status_verified") }
        if isMock { return L.t("security_status_mock") }
        return L.t("security_status_unverified")
    }

    private var statusColor: Color {
        if isVerified { return greenColor }
        if isMock { return orangeColor }
        return redColor
    }

    private var guardText: String {
        if isVerified { return L.t("security_guard_active") }
        if isMock { return L.t("security_guard_test") }
        return L.t("security_guard_risk")
    }

    private var guardColor: Color {
        if isVerified { return blueColor }
        if isMock { return orangeColor }
        return redColor
    }

    private var lastCheckText: String {
        guard lastTime > 0 else { return L.t("security_not_checked") }
        let date = Date(timeIntervalSince1970: Double(lastTime) / 1000)
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy, HH:mm"
        return L.t("security_last_check") + f.string(from: date)
    }

    private func openSource() {
        if let url = URL(string: "https://github.com/VerifyBlind/VerifyBlind-iOS") {
            UIApplication.shared.open(url)
        }
    }
}
