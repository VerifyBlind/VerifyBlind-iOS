import SwiftUI
import UIKit

/// Partner consent bottom sheet — Android `ConsentBottomSheet` + `bottomsheet_consent.xml` portu.
/// Partner ad/logo, doğrulanacak bilgiler (scopes), KVKK onay kutusu, Onayla/Reddet.
/// Dil [[feedback_never_share_identity_wording]] uyumlu ("DOĞRULANACAK BİLGİLER").
struct ConsentBottomSheet: View {
    let info: PartnerInfoResponse
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var kvkkChecked = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHandle()

            logo.padding(.bottom, 16)

            Text(info.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center)

            Text(L.t("consent_request_subtitle"))
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.bottom, 24)

            Text(L.t("consent_section_shared"))
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(scopeList, id: \.self) { scope in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundColor(Theme.success)
                        Text(scope).font(.system(size: 14)).foregroundColor(Theme.onSurface)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(L.t("consent_scope_footer"))
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)

            // KVKK onay kutusu
            Button { kvkkChecked.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: kvkkChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundColor(kvkkChecked ? Theme.themePrimary : Theme.onSurfaceVariant)
                    Text(L.t("consent_kvkk_text"))
                        .font(.system(size: 13)).foregroundColor(Theme.onSurface)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)

            // Onayla (consent gradient, radius 14)
            Button(action: { if kvkkChecked { onApprove() } }) {
                Text(L.t("btn_approve"))
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Theme.consentButtonGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(kvkkChecked ? 1 : 0.5)
            }
            .disabled(!kvkkChecked)
            .padding(.bottom, 12)

            Button(action: onReject) {
                Text(L.t("consent_btn_reject"))
                    .font(.system(size: 15)).foregroundColor(Theme.onSurfaceVariant)
                    .padding(12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .background(Theme.surface)
        .clipShape(RoundedCorners(radius: 24, corners: [.topLeft, .topRight]))
    }

    private var logo: some View {
        ZStack {
            Circle().fill(Theme.themePrimary).frame(width: 72, height: 72)
            if let b64 = info.logoBase64, let data = Data(base64Encoded: stripDataURL(b64)), let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: 72, height: 72).clipShape(Circle())
            } else {
                Text(initials).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
            }
        }
    }

    private var initials: String {
        let first = info.name.first.map { String($0).uppercased() } ?? "?"
        return first
    }

    private var scopeList: [String] {
        guard let scopes = info.scopes, !scopes.isEmpty else { return [L.t("consent_default_scope")] }
        return scopes.map(scopeText)
    }

    private func scopeText(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.contains("user") { return L.t("scope_user_id") }
        if lower.contains("age") {
            let parts = s.split(whereSeparator: { $0 == ":" || $0 == "_" || $0 == "=" })
            let val = parts.count > 1 ? String(parts.last!) : "18+"
            return L.t("scope_age", val)
        }
        return s
    }

    private func stripDataURL(_ s: String) -> String {
        if let range = s.range(of: "base64,") { return String(s[range.upperBound...]) }
        return s
    }
}

/// Belirli köşeleri yuvarlatma yardımcı şekli (bottom sheet üst köşeleri).
struct RoundedCorners: Shape {
    var radius: CGFloat = 16
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
