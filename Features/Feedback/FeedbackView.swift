import SwiftUI
import UIKit

/// "Bize Ulaşın" / geri bildirim ekranı — Android `FeedbackFragment` paritesi.
/// `POST /api/feedback` (`source="mobile"` → Turnstile yok). Cihaz/sürüm bilgisi triyaj için
/// mesajın sonuna eklenir (sunucuda ayrı alan yok). Ayarlar'dan `.sheet` ile sunulur.
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    /// Akış içinden açıldığında konu satırı hazır gelir ("Kart ekleme sorunu: Çip okuma") —
    /// kullanıcı nerede takıldığını anlatmak zorunda kalmasın.
    let prefilledSubject: String?

    /// Başarısız denemedeki selfie. Yalnızca kullanıcı AÇIKÇA onaylarsa gönderilir; onay kutusu
    /// varsayılan olarak KAPALIDIR ve bu görüntü hiçbir koşulda otomatik iletilmez.
    let diagnosticPhoto: Data?

    /// Çip fotoğrafının hizalanmış 112×112 kırpımı — AYRI onay anahtarına bağlı.
    ///
    /// Neden ayrı: benzerlik ikili bir fonksiyondur, tek tarafla skor yeniden üretilemez; yani bu ek
    /// teşhis için gerçekten gerekli. Ama selfie kullanıcının o an çektirdiği kare, bu ise kimlik
    /// belgesinin içinden çıkan resmî görüntü. Selfie anahtarını açmak bunu açmış SAYMAZ.
    let chipPhoto: Data?

    /// Son denemenin skaler ölçüleri (skor, luma, açı, adım…) ve huni akış anahtarı — mesajın
    /// sonuna eklenir. Görüntü değil, biyometrik veri değil → rıza gerektirmez.
    let diagnostics: String?
    let flowId: String?

    init(prefilledSubject: String? = nil,
         diagnosticPhoto: Data? = nil,
         chipPhoto: Data? = nil,
         diagnostics: String? = nil,
         flowId: String? = nil) {
        self.prefilledSubject = prefilledSubject
        self.diagnosticPhoto = diagnosticPhoto
        self.chipPhoto = chipPhoto
        self.diagnostics = diagnostics
        self.flowId = flowId
        _subject = State(initialValue: prefilledSubject ?? "")
    }

    @State private var name = ""
    @State private var email = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var done = false
    @State private var sharePhoto = false      // varsayılan KAPALI — rıza aktif bir eylem olmalı
    @State private var shareChipPhoto = false  // AYRI rıza; selfie anahtarı bunu açmaz
    @State private var wantsFixNotice = false  // "düzeltince haber ver" — varsayılan KAPALI

    /// Bildirim kutusu YALNIZ elde bir push token varsa gösterilir. Token yoksa (kullanıcı
    /// bildirim iznini hiç vermemiş) kutuyu göstermek, tutamayacağımız bir söz vermek olurdu.
    private var canPromiseNotice: Bool { !(AppPrefs.apnsToken ?? "").isEmpty }

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

                // Yıldızın anlamı bir konvansiyon — yazılı olmadan garanti değil.
                Text(L.t("feedback_required_note"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.error)

                field(title: "feedback_name_label", text: $name, hint: "feedback_name_hint", isEmail: false)
                field(title: "feedback_email_label", text: $email, hint: "feedback_email_hint", isEmail: true)
                field(title: "feedback_subject_label", text: $subject, hint: "feedback_subject_hint", isEmail: false, required: true)
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

                // Rızalı teşhis fotoğrafı — YALNIZ akış içinden gelindiyse ve elde bir kare varsa
                // görünür. Kapalı başlar: rıza aktif bir eylem olmalı, varsayılan olamaz.
                if diagnosticPhoto != nil {
                    Toggle(isOn: $sharePhoto) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("feedback_photo_consent"))
                                .font(.system(size: 14))
                                .foregroundColor(Theme.onSurface)
                            Text(L.t("feedback_photo_consent_note"))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .padding(.top, 8)
                }

                // Çip fotoğrafı: AYRI anahtar. Selfie kullanıcının o an çektirdiği kare, bu ise
                // kimlik belgesinin içinden çıkan resmî görüntü — farklı kategori, farklı rıza.
                if chipPhoto != nil {
                    Toggle(isOn: $shareChipPhoto) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("feedback_chip_consent"))
                                .font(.system(size: 14))
                                .foregroundColor(Theme.onSurface)
                            Text(L.t("feedback_chip_consent_note"))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .padding(.top, 4)
                }

                // "Düzeltince haber ver" — e-posta bırakmayan kullanıcıya ulaşabilmenin tek yolu.
                // Fotoğraf rızalarından AYRI: orada paylaşılan bir görüntü, burada kalıcı bir cihaz
                // tanımlayıcısı söz konusu. Token yoksa kutu hiç çıkmaz (bkz. canPromiseNotice).
                if canPromiseNotice {
                    Toggle(isOn: $wantsFixNotice) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("feedback_notify_consent"))
                                .font(.system(size: 14))
                                .foregroundColor(Theme.onSurface)
                            Text(L.t("feedback_notify_consent_note"))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .padding(.top, 4)
                }

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

    private func field(title: String, text: Binding<String>, hint: String, isEmail: Bool,
                       required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel(title, required: required)
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

    /// Etiket + (zorunluysa) kırmızı yıldız. Zorunluluk formu göndermeden ÖNCE görünmeli:
    /// eskiden kullanıcı "Gönder"e basana kadar hangi alanın gerektiğini öğrenemiyordu.
    private func requiredLabel(_ key: String, required: Bool) -> some View {
        HStack(spacing: 3) {
            Text(L.t(key)).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.onSurface)
            if required {
                Text(L.t("feedback_required_marker"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.error)
                    .accessibilityHidden(true)
            }
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel("feedback_message_label", required: true)
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

        // Ad da e-posta gibi İSTEĞE BAĞLI. Bu kutu çoğunlukla bir hatanın hemen ardından açılıyor
        // ve amacımız sorunu toplamak — kimin yaşadığını öğrenmek değil. Zorunlu tek bir alan bile
        // insanı geri çeviriyor ve elde kalan tek şey sessizlik oluyor. Zorunlu olan yalnız
        // konu+mesaj (ekranda kırmızı yıldızla işaretli). Adres GİRİLİRSE biçimi doğrulanır —
        // yanlış yazılmış adres, adres yokluğundan kötüdür: kullanıcı boşuna yanıt bekler.
        if s.isEmpty || m.isEmpty {
            errorText = L.t("feedback_error_missing"); return
        }
        if !e.isEmpty, !isValidEmail(e) {
            errorText = L.t("feedback_error_invalid_email"); return
        }

        let lang = (Locale.current.language.languageCode?.identifier == "en") ? "en" : "tr"
        let full = m + "\n\n" + deviceMetadata()

        isSending = true
        defer { isSending = false }
        do {
            try await FeedbackService.shared.send(
                FeedbackRequest(
                    name: n, email: e, subject: s, message: full, source: "mobile", language: lang,
                    photo_consent: sharePhoto && diagnosticPhoto != nil,
                    photo_base64: sharePhoto ? diagnosticPhoto?.base64EncodedString() : nil,
                    // Çip kırpımı AYRI kapıdan geçer: selfie anahtarı açık olsa bile bu anahtar
                    // kapalıysa veri OKUNMAZ (sunucuda da kapılar ayrı).
                    chip_photo_consent: shareChipPhoto && chipPhoto != nil,
                    chip_photo_base64: shareChipPhoto ? chipPhoto?.base64EncodedString() : nil,
                    // Aşağıdakiler mesaj gövdesinde de var (bkz. deviceMetadata); ayrı alan olarak
                    // gitmelerinin sebebi sunucunun kaydı SORGULANABİLİR tutması — destek postası
                    // artık tek arşiv değil.
                    flow_id: flowId,
                    platform: "ios",
                    app_version: Self.appVersionString,
                    diagnostics: diagnostics,
                    notify_consent: wantsFixNotice && canPromiseNotice,
                    push_token: wantsFixNotice ? AppPrefs.apnsToken : nil)
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

    /// Triyaj için mesaja eklenen cihaz/sürüm + teşhis bloğu (kullanıcı-arayüzü değil → sabit etiket).
    /// Cihaz adı: pazarlama adı + ham tanımlayıcı ("iPhone 12 (iPhone13,2)"); bilinmeyen model → ham id.
    /// Pazarlama-adı eşlemesi tek kaynaktan gelir (`DeviceInfo`).
    ///
    /// Buraya kadar yalnız cihaz ve sürüm gidiyordu: destek kutusundaki posta "benzerlik yetersiz"
    /// diyor, yanında 112×112'lik bir kırpım duruyor ve HİÇBİR SAYI yoktu — skor kaçtı, kare ne
    /// kadar karanlıktı, kafa ne kadar dönüktü, hiçbiri bilinmiyordu. Hepsi zaten hesaplanıyor ve
    /// cihazdaki loga yazılıyordu; buraya taşınmaları skaler oldukları için ücretsiz.
    ///
    /// `flowId` ise anlatıyı hunideki satıra bağlayan tek anahtar.
    /// "1.0.3+187" — hem teşhis bloğunda hem de sözleşmedeki `app_version` alanında kullanılır.
    static var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)+\(b)"
    }

    private func deviceMetadata() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let id = DeviceInfo.hardwareIdentifier()
        let device = DeviceInfo.marketingName(for: id).map { "\($0) (\(id))" } ?? id
        let os = UIDevice.current.systemVersion
        var out = "───\nUygulama / App: iOS v\(v) (\(b))\nCihaz / Device: \(device)\nOS: iOS \(os)"
        if let flowId, !flowId.isEmpty { out += "\nAkış / Flow: \(flowId)" }
        if let diagnostics, !diagnostics.isEmpty { out += "\n" + diagnostics }
        return out
    }
}
