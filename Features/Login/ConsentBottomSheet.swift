import SwiftUI
import UIKit

/// Partner consent bottom sheet — Android `ConsentBottomSheet` + `bottomsheet_consent.xml` portu.
/// Doğrulanacak bilgiler `validations` JSON'undan (user_id / age) madde işaretiyle, "Aydınlatma
/// Metnini Oku" linki, KVKK onay kutusu, Onayla/Reddet. Dil [[feedback_never_share_identity_wording]].
struct ConsentBottomSheet: View {
    let info: PartnerInfoResponse
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var kvkkChecked = AppPrefs.kvkkConsentAccepted
    @State private var privacyDoc: PrivacyDoc?
    @State private var loadingPrivacy = false

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

            // Doğrulanacak bilgiler — Android: madde işareti "•", validations'tan türetilir.
            VStack(alignment: .leading, spacing: 8) {
                // user_id maddesi + "Bu nedir?" — link HEMEN onun bitişinde (en altta değil).
                if hasUserId {
                    Text("•  \(L.t("scope_user_id"))")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        privacyDoc = PrivacyDoc(text: L.t("scope_user_id_detail_body"),
                                                title: L.t("scope_user_id_detail_title"))
                    } label: {
                        Text(L.t("scope_user_id_whatis"))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.themePrimary)
                            .underline()
                    }
                    .padding(.leading, 18)  // "•  " genişliği kadar — madde metniyle hizalı
                }
                // Diğer maddeler (age vb.) — user_id zaten yukarıda ayrı render edildi.
                ForEach(otherScopeItems, id: \.self) { scope in
                    Text("•  \(scope)")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Aydınlatma Metnini Oku (altı çizili mavi link → /api/kvkk/privacy-notice)
                Button { fetchPrivacy() } label: {
                    Text(L.t("read_privacy_notice"))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.themePrimary)
                        .underline()
                }
                .padding(.top, 6)
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

            Button(action: approve) {
                Text(L.t("btn_approve"))
                    .textCase(.uppercase) // Android MaterialButton textAllCaps paritesi (APPROVE / ONAYLA)
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Theme.consentButtonGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(kvkkChecked ? 1 : 0.5)
            }
            .disabled(!kvkkChecked)
            .padding(.bottom, 12)

            Button(action: onReject) {
                Text(L.t("btn_reject"))
                    .font(.system(size: 15)).foregroundColor(Theme.onSurfaceVariant)
                    .padding(12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .background(Theme.surface)
        .clipShape(RoundedCorners(radius: 24, corners: [.topLeft, .topRight]))
        // .sheet(item:) — metni item içinde taşır; isPresented'in async set'te bayat snapshot
        // yakalama yarışını (boş içerik) engeller.
        .sheet(item: $privacyDoc) { doc in PrivacyNoticeView(text: doc.text, title: doc.title) }
    }

    // Logo VARSA: şeffaf zemin (sadece görsel). YOKSA: #1287BE + baş harfler (Android paritesi).
    private var logo: some View {
        Group {
            if let ui = partnerLogoImage {
                Image(uiImage: ui).resizable().scaledToFit().frame(width: 72, height: 72)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: "#1287BE")).frame(width: 72, height: 72)
                    Text(initials).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                }
            }
        }
    }

    private var partnerLogoImage: UIImage? {
        guard let b64 = info.logoBase64, !b64.isEmpty,
              let data = Data(base64Encoded: stripDataURL(b64)), let ui = UIImage(data: data) else { return nil }
        return ui
    }

    private var initials: String {
        let parts = info.name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2 { return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(info.name.prefix(2)).uppercased()
    }

    /// Android: validations JSON object'inden user_id / age maddeleri (scopes listesi DEĞİL).
    private var scopeItems: [String] {
        var items: [String] = []
        if case .object(let obj)? = info.validations {
            if obj["user_id"] != nil { items.append(L.t("scope_user_id")) }
            if let age = obj["age"] { items.append(L.t("scope_age", jsonString(age))) }
        }
        if items.isEmpty { items.append(L.t("consent_default_scope")) }
        return items
    }

    /// user_id istendi mi — "Bu nedir?" detay linkini göstermek için.
    private var hasUserId: Bool {
        if case .object(let obj)? = info.validations { return obj["user_id"] != nil }
        return false
    }

    /// user_id dışındaki maddeler (user_id ayrı render edilir; link onun bitişinde gösterilir).
    private var otherScopeItems: [String] {
        scopeItems.filter { $0 != L.t("scope_user_id") }
    }

    private func jsonString(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    private func approve() {
        guard kvkkChecked else { return }
        AppPrefs.kvkkConsentAccepted = true
        onApprove()
    }

    private func fetchPrivacy() {
        guard !loadingPrivacy else { return }
        loadingPrivacy = true
        Task { @MainActor in
            defer { loadingPrivacy = false }
            var text = L.t("privacy_notice_load_failed")
            do {
                let resp = try await VerifyAPI.shared.privacyNotice()
                let t = resp.text ?? ""
                text = t.isEmpty ? L.t("privacy_notice_load_error") : t
            } catch {
                Log.warning("Aydınlatma metni yüklenemedi: \(error.localizedDescription)", category: .flow)
            }
            privacyDoc = PrivacyDoc(text: text)
        }
    }

    private func stripDataURL(_ s: String) -> String {
        if let range = s.range(of: "base64,") { return String(s[range.upperBound...]) }
        return s
    }
}

/// .sheet(item:) için metni taşıyan Identifiable sarmalayıcı (bayat-snapshot yarışını önler).
/// Aydınlatma metni VEYA "Bu kod nedir?" detayı için ortak; başlık opsiyonel (varsayılan aydınlatma metni).
struct PrivacyDoc: Identifiable {
    let id = UUID()
    let text: String
    var title: String? = nil
}

/// Aydınlatma metni / bilgi görüntüleyici (Android AlertDialog eşdeğeri).
struct PrivacyNoticeView: View {
    let text: String
    var title: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(title ?? L.t("privacy_notice_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("btn_close")) { dismiss() } } }
        }
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
