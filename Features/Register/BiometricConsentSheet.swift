import SwiftUI

/// Biyometrik veri rızası — Android `BiometricConsentBottomSheet` + `bottomsheet_biometric_consent.xml`
/// portu. Liveness'tan HEMEN ÖNCE gösterilir (KVKK md.6 — yüz verisi işleme rızası). Onaylanmadan
/// onay butonu pasif. Hem gerçek hem demo akışta.
struct BiometricConsentSheet: View {
    var isDemo: Bool = false
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var checked = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHandle()

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.lockIconBg)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.lockIconStroke, lineWidth: 1.5))
                    .frame(width: 72, height: 72)
                Text("🔬").font(.system(size: 30))
            }
            .padding(.bottom, 16)

            Text(L.t("biometric_consent_title"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.onSurface)
                .padding(.bottom, 20)

            ScrollView {
                Text(L.t("biometric_consent_text"))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .padding(.bottom, 20)

            Button { checked.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundColor(checked ? Theme.themePrimary : Theme.onSurfaceVariant)
                    Text(L.t("biometric_consent_checkbox"))
                        .font(.system(size: 13)).foregroundColor(Theme.onSurface)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)

            Button { if checked { onApprove() } } label: {
                Text(L.t("btn_approve_biometric"))
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Theme.consentButtonGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(checked ? 1 : 0.5)
            }
            .disabled(!checked)
            .padding(.bottom, 12)

            Button(action: onReject) {
                Text(L.t("btn_reject_biometric"))
                    .font(.system(size: 15)).foregroundColor(Theme.onSurfaceVariant)
                    .padding(12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .background(Theme.surface)
        .clipShape(RoundedCorners(radius: 24, corners: [.topLeft, .topRight]))
        // Demo: rızayı otomatik işaretle + 3sn sonra "Onayla" (normal akış etkilenmez).
        // Geç tetiklenen oto-onay `approveBiometricConsent()` içindeki adım koruması ile güvenli.
        .onAppear {
            guard isDemo else { return }
            checked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { onApprove() }
        }
    }
}
