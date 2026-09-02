import SwiftUI

/// Hukuki metin kabul kapısı (clickwrap) — Android `LegalTermsActivity` paritesi.
///
/// Engelleyici tam-ekran overlay olarak sunulur: kabul edilmeden altındaki uygulamaya erişilemez,
/// kapatma jesti yoktur. Onay kutusu işaretlenmeden "Kabul et" etkinleşmez. Kabul edilince sürüm +
/// zaman damgası cihaza yazılır — zero-knowledge mimaride kanıt budur (bkz. `LegalTerms`).
struct LegalTermsGate: View {

    /// Kapının dayattığı sürüm — kabul bununla kaydedilir.
    let requiredVersion: String
    /// Metin güncellemesi bağlamında farklı bir giriş metni gösterilir.
    let isUpdate: Bool
    let onAccept: () -> Void

    @State private var agreed = false

    private static let termsURL = "https://verifyblind.com/terms"
    private static let dpaURL = "https://verifyblind.com/dpa"
    private static let disclosureURL = "https://verifyblind.com/disclosure"

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L.t("legal_terms_title"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.onSurface)

                        Text(L.t(isUpdate ? "legal_terms_updated_intro" : "legal_terms_intro"))
                            .font(.system(size: 14))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)

                        // Kısa özet: kullanıcı metinleri açmadan da temel yükümlülükleri görür.
                        Text(L.t("legal_terms_summary_title"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.onSurface)
                            .padding(.top, 8)

                        Text(L.t("legal_terms_summary_body"))
                            .font(.system(size: 14))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 4) {
                            linkRow("legal_terms_link_terms", url: Self.termsURL)
                            linkRow("legal_terms_link_dpa", url: Self.dpaURL)
                            linkRow("legal_terms_link_disclosure", url: Self.disclosureURL)
                        }
                        .padding(.top, 8)

                        Text(L.t("legal_terms_version_label", requiredVersion))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.onSurfaceVariant)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                }

                VStack(spacing: 12) {
                    Button {
                        agreed.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: agreed ? "checkmark.square.fill" : "square")
                                .font(.system(size: 20))
                                .foregroundColor(agreed ? Theme.themePrimary : Theme.onSurfaceVariant)
                            Text(L.t("legal_terms_checkbox"))
                                .font(.system(size: 14))
                                .foregroundColor(Theme.onSurface)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(agreed ? [.isSelected] : [])

                    Button {
                        LegalTerms.recordAcceptance(version: requiredVersion)
                        Log.info("Hukuki metin kabul edildi: sürüm \(requiredVersion)", category: .app)
                        onAccept()
                    } label: {
                        Text(L.t("legal_terms_accept"))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(agreed ? Theme.themePrimary : Theme.onSurfaceVariant.opacity(0.3),
                                        in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!agreed)

                    // iOS'ta uygulamayı programatik kapatmak App Store kurallarına aykırıdır
                    // (Android'deki "Reddet ve çık" burada bilinçli olarak yok); reddeden kullanıcı
                    // uygulamayı kendisi kapatır — kapı zaten geçilemez.
                    Text(L.t("legal_terms_decline_hint"))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .background(Theme.surface)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func linkRow(_ key: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            Text(L.t(key))
                .font(.system(size: 15))
                .foregroundColor(Theme.themePrimary)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
