import SwiftUI

/// Sistem Güvenliği — Android `SecurityInfoFragment` + `fragment_security_info.xml` **birebir** portu.
/// Attestation teşhisini `AppPrefs` last_* bayraklarından okur (handshake + attestation doğrulaması
/// `HandshakeService.recordAttestationDiagnostics` ile doldurur): guard durumu, PCR0, yayıncı,
/// doğrulama durumu (üçlü), son kontrol zamanı, kaynak kodu linki.
///
/// Düzen (Android layout sırası): üst kalkan kartı (logo + guard + AWS) → "Güvenlik Detayları"
/// başlığı → PCR0 kartı → Yayıncı kartı → Doğrulama kartı → GitHub kaynak satırı → footer.
struct SecurityInfoView: View {
    let onBack: () -> Void

    @State private var pcr0 = AppPrefs.lastPcr0 ?? "N/A"
    @State private var isVerified = AppPrefs.lastHardwareVerified
    @State private var isMock = AppPrefs.lastIsMock
    @State private var lastTime = AppPrefs.lastAttestationTime
    @State private var checking = true

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
                    shieldHeaderCard

                    Text(L.t("security_details_label"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .tracking(1.1)
                        .padding(.leading, 8)
                        .padding(.top, 8)

                    pcr0Card
                    publisherCard
                    verificationCard
                    sourceRow

                    Text(L.t("security_footer"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .task { await refresh() }
    }

    /// Canlı doğrulama (Q2): ekran açılınca yan-etkisiz attestation sondası çalıştır, sonuca göre
    /// güncelle. Ağ yoksa (.unreachable) snapshot + eski "son kontrol" korunur (bayatlık görünür).
    private func refresh() async {
        checking = true
        switch await HandshakeService.shared.probeAttestation() {
        case .verified(let p):
            pcr0 = p                                    // probeAttestation last_* prefs'i zaten yazdı
            isVerified = AppPrefs.lastHardwareVerified
            isMock = AppPrefs.lastIsMock
            lastTime = AppPrefs.lastAttestationTime
        case .failed:
            isVerified = false; isMock = false          // dürüst kırmızı "doğrulanamadı"
            lastTime = Int64(Date().timeIntervalSince1970 * 1000)
        case .unreachable:
            break                                       // snapshot + eski "son kontrol" kalır
        }
        checking = false
    }

    // MARK: - Kartlar

    /// Üst kalkan kartı (Android `ivShieldLarge` + `tvGuardStatus` + AWS etiketi — hepsi ortalanmış).
    private var shieldHeaderCard: some View {
        CardSurface(padding: 24) {
            VStack(spacing: 0) {
                Image("logo")
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)

                Text(guardText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(guardColor)
                    .tracking(1.4)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                Text(L.t("security_aws_label"))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
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

    /// Yayıncı kartı (Android: başlık + logo(18) + "verifyblind.com" + açıklama).
    private var publisherCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("security_publisher_label")).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                HStack(spacing: 8) {
                    Image("logo").resizable().scaledToFit().frame(width: 18, height: 18)
                    Text("verifyblind.com").font(.system(size: 13)).foregroundColor(Theme.themePrimary)
                }
                Text(L.t("security_publisher_desc")).font(.system(size: 11)).foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }

    /// Doğrulama kartı (Android: başlık + durum metni[renkli] + son kontrol).
    private var verificationCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("security_verify_label")).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundColor(statusColor)
                    .padding(.top, 4)
                Text(lastCheckText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.top, 4)
            }
        }
    }

    /// GitHub kaynak satırı (Android `btnViewSource` kart: kod ikonu + metin + sağ ok).
    private var sourceRow: some View {
        Button(action: openSource) {
            CardSurface {
                HStack(spacing: 16) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 20)).foregroundColor(Theme.onSurfaceVariant)
                    Text(L.t("security_view_source"))
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Durum mantığı (Android paritesi)

    private var statusText: String {
        if checking { return L.t("security_checking") }
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
