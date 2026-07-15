import SwiftUI
import UIKit

/// "Bize Ulaşın" / geri bildirim ekranı — Android `FeedbackFragment` paritesi.
/// `POST /api/feedback` (`source="mobile"` → Turnstile yok). Cihaz/sürüm bilgisi triyaj için
/// mesajın sonuna eklenir (sunucuda ayrı alan yok). Ayarlar'dan `.sheet` ile sunulur.
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var done = false

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("feedback_title"), titleColor: Theme.onSurface, titleSize: 18) { dismiss() }
            if done {
                successView
            } else {
                formView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L.t("feedback_intro"))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.onSurfaceVariant)

                field(title: "feedback_name_label", text: $name, hint: "feedback_name_hint", isEmail: false)
                field(title: "feedback_email_label", text: $email, hint: "feedback_email_hint", isEmail: true)
                field(title: "feedback_subject_label", text: $subject, hint: "feedback_subject_hint", isEmail: false)
                messageField

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.error)
                }

                PrimaryGradientButton(title: L.t("feedback_submit"), systemImage: "paperplane.fill",
                                      enabled: !isSending, loading: isSending, height: 52, fontSize: 16) {
                    Task { await submit() }
                }
                .padding(.top, 4)

                Text(L.t("feedback_privacy_note"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
    }

    private func field(title: String, text: Binding<String>, hint: String, isEmail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t(title)).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
            CardSurface(padding: 14) {
                TextField(L.t(hint), text: text)
                    .foregroundColor(Theme.onSurface)
                    .keyboardType(isEmail ? .emailAddress : .default)
                    .textInputAutocapitalization(isEmail ? .never : .sentences)
                    .autocorrectionDisabled(isEmail)
                    .textContentType(isEmail ? .emailAddress : nil)
                    .disabled(isSending)
            }
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("feedback_message_label")).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
            CardSurface(padding: 14) {
                TextField(L.t("feedback_message_hint"), text: $message, axis: .vertical)
                    .foregroundColor(Theme.onSurface)
                    .lineLimit(5...10)
                    .disabled(isSending)
            }
        }
    }

    // MARK: - Başarılı

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()
            IconCircle(systemName: "checkmark", fill: Theme.badgeGreenFill, tint: Theme.badgeGreenText, size: 56)
            Text(L.t("feedback_success"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center)
            PrimaryGradientButton(title: L.t("btn_close"), height: 52, fontSize: 16) { dismiss() }
                .padding(.horizontal, 40)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Gönderim

    @MainActor
    private func submit() async {
        errorText = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if n.isEmpty || e.isEmpty || s.isEmpty || m.isEmpty {
            errorText = L.t("feedback_error_missing"); return
        }
        if !isValidEmail(e) {
            errorText = L.t("feedback_error_invalid_email"); return
        }

        let lang = (Locale.current.language.languageCode?.identifier == "en") ? "en" : "tr"
        let full = m + "\n\n" + deviceMetadata()

        isSending = true
        defer { isSending = false }
        do {
            try await FeedbackService.shared.send(
                FeedbackRequest(name: n, email: e, subject: s, message: full, source: "mobile", language: lang)
            )
            done = true
        } catch {
            errorText = errorMessage(for: error)
        }
    }

    private func isValidEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil && s.count <= 256
    }

    /// HTTP/ağ koduna göre yerelleştirilmiş hata mesajı (Android `errorMessageFor` paritesi).
    private func errorMessage(for error: Error) -> String {
        guard let fe = error as? FeedbackError else { return L.t("feedback_error_generic") }
        switch fe {
        case .network:
            return L.t("error_connection_generic")
        case .http(let status, let code):
            if status == 429 { return L.t("feedback_error_rate_limited") }
            if (500...599).contains(status) {
                return (status == 503 || (520...527).contains(status))
                    ? L.t("error_service_unavailable")
                    : L.t("error_server_temporary")
            }
            switch code {
            case "INVALID_EMAIL": return L.t("feedback_error_invalid_email")
            case "TOO_LONG":      return L.t("feedback_error_too_long")
            case "MISSING_FIELDS": return L.t("feedback_error_missing")
            default:              return L.t("feedback_error_generic")
            }
        }
    }

    /// Triyaj için mesaja eklenen cihaz/sürüm bloğu (kullanıcı-arayüzü değil → sabit etiket).
    /// Cihaz adı: pazarlama adı + ham tanımlayıcı ("iPhone 12 (iPhone13,2)"); bilinmeyen model → ham id.
    /// Pazarlama-adı eşlemesi tek kaynaktan gelir ([[DeviceInfo]]).
    private func deviceMetadata() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let id = DeviceInfo.hardwareIdentifier()
        let device = DeviceInfo.marketingName(for: id).map { "\($0) (\(id))" } ?? id
        let os = UIDevice.current.systemVersion
        return "───\nUygulama / App: iOS v\(v) (\(b))\nCihaz / Device: \(device)\nOS: iOS \(os)"
    }
}
