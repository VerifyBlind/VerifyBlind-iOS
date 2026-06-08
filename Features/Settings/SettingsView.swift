import SwiftUI

/// Ayarlar — Android `SettingsFragment` + `fragment_settings.xml` tam portu (Aşama 6).
/// Satırlar: Biyometrik Kilit · İşlem Geçmişi · Sistem Güvenliği · Nasıl Çalışır · SSS · Şifreli
/// Yedekleme · (Kartımı Engelle — Android paritesi: gizli) · Verilerimi Sil · Dil · Gizlilik · Sürüm.
struct SettingsView: View {
    let onBack: () -> Void
    let onHistory: () -> Void
    let onBackup: () -> Void
    let onHelp: () -> Void
    let onSecurity: () -> Void

    @EnvironmentObject var appState: AppState

    @State private var biometricEnabled = AppPrefs.biometricEnabled
    @State private var showLanguageDialog = false
    @State private var showResetConfirm = false
    @State private var showBlockCardConfirm = false
    @State private var infoMessage: String?      // dil/blok/sıfırlama bilgi alert'i
    @State private var isWorking = false

    // Android `cardBlockCard && false` → kalıcı GİZLİ. Kart bloke etmek geri alınamaz (gerçek kartı
    // kullanılamaz kılar); backend akışı hazır olana dek Android'de olduğu gibi kapalı tutulur.
    private let blockCardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(spacing: 8) {
                    biometricRow

                    navRow(icon: "clock.arrow.circlepath", fill: Theme.cyanSoft, tint: Theme.chipCyan,
                           title: "settings_history_title", desc: "settings_history_desc", action: onHistory)

                    navRow(icon: "lock.shield", fill: Theme.blueSoft, tint: Theme.themePrimary,
                           title: "settings_security_title", desc: "settings_security_desc", action: onSecurity)

                    navRow(icon: "questionmark.circle", fill: Theme.blueSoft, tint: Theme.themePrimary,
                           title: "settings_help_title", desc: "settings_help_desc", action: onHelp)

                    navRow(icon: "text.bubble", fill: Theme.cyanSoft, tint: Theme.chipCyan,
                           title: "settings_faq_title", desc: "settings_faq_desc", action: onHelp)

                    navRow(icon: "lock.icloud", fill: Theme.blueSoft, tint: Theme.themePrimary,
                           title: "settings_backup_title", desc: "settings_backup_desc", action: onBackup)

                    if blockCardVisible && appState.hasCard {
                        navRow(icon: "creditcard.trianglebadge.exclamationmark", fill: Theme.cyanSoft, tint: Theme.error,
                               title: "settings_block_card_title", desc: "settings_block_card_desc") {
                            showBlockCardConfirm = true
                        }
                    }

                    languageRow

                    navRow(icon: "trash", fill: Theme.cyanSoft, tint: Theme.error,
                           title: "settings_reset_title", desc: "settings_reset_desc") {
                        showResetConfirm = true
                    }

                    privacyRow
                    versionRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView().scaleEffect(1.2) } }
        // Dil seçimi
        .confirmationDialog(L.t("language_dialog_title"), isPresented: $showLanguageDialog, titleVisibility: .visible) {
            Button(L.t("lang_system")) { selectLanguage("system") }
            Button(L.t("lang_turkish")) { selectLanguage("tr") }
            Button(L.t("lang_english")) { selectLanguage("en") }
            Button(L.t("btn_cancel"), role: .cancel) {}
        }
        // Verilerimi Sil onayı
        .confirmationDialog(L.t("reset_wallet_title"), isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button(L.t("reset_wallet_confirm"), role: .destructive) { Task { await performReset() } }
            Button(L.t("btn_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("reset_wallet_message"))
        }
        // Kartımı Engelle onayı
        .confirmationDialog(L.t("block_card_confirm_title"), isPresented: $showBlockCardConfirm, titleVisibility: .visible) {
            Button(L.t("block_card_confirm_button"), role: .destructive) { Task { await performBlockCard() } }
            Button(L.t("btn_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("block_card_confirm_message"))
        }
        // Bilgi (dil yeniden başlat / blok sonucu / sıfırlama hatası)
        .alert(infoMessage ?? "", isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })) {
            Button(L.t("common_ok"), role: .cancel) {}
        }
    }

    // MARK: - Satırlar

    private var biometricRow: some View {
        CardSurface {
            HStack(spacing: 16) {
                IconCircle(systemName: "faceid", fill: Theme.blueSoft, tint: Theme.themePrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("settings_biometric_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                    Text(L.t("settings_biometric_desc")).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                }
                Spacer()
                Toggle("", isOn: $biometricEnabled)
                    .labelsHidden()
                    .tint(Theme.themePrimary)
                    .onChange(of: biometricEnabled) { v in AppPrefs.biometricEnabled = v }
            }
        }
    }

    private var languageRow: some View {
        Button(action: { showLanguageDialog = true }) {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: "globe", fill: Theme.blueSoft, tint: Theme.themePrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("language_dialog_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                        Text(currentLanguageLabel).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var privacyRow: some View {
        Button(action: openPrivacyPolicy) {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: "hand.raised", fill: Theme.cyanSoft, tint: Theme.chipCyan)
                    Text(L.t("privacy_notice_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var versionRow: some View {
        Text(appVersion)   // Android `tvVersion`: "1.0.0 (1)" düz metin, etiketsiz
            .font(.system(size: 12))
            .foregroundColor(Theme.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }

    /// Tıklanabilir kart satırı (ikon + başlık + açıklama + chevron).
    private func navRow(icon: String, fill: Color, tint: Color, title: String, desc: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: icon, fill: fill, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(title)).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                        Text(L.t(desc)).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Yardımcılar

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var currentLanguageLabel: String {
        switch AppPrefs.appLanguage {
        case "tr": return L.t("lang_turkish")
        case "en": return L.t("lang_english")
        default:   return L.t("lang_system")
        }
    }

    /// Android `setApplicationLocales` eşdeğeri. iOS bundle dilini canlı değiştiremez → `AppleLanguages`
    /// override + yeniden başlatma bilgisi.
    private func selectLanguage(_ code: String) {
        AppPrefs.appLanguage = code
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        infoMessage = L.t("language_restart_hint")
    }

    private func openPrivacyPolicy() {
        let lang = (Locale.current.language.languageCode?.identifier == "tr") ? "tr" : "en"
        if let url = URL(string: "https://verifyblind.com/\(lang)/gizlilik") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - İşlemler

    private func performReset() async {
        // Biyometrik onay (Android BiometricHelper.authenticate).
        do {
            try await BiometricGate.authenticate(reason: L.t("biometric_subtitle_decrypt"))
        } catch {
            return // iptal
        }
        isWorking = true
        await DataWipe.wipeAll()
        isWorking = false
        appState.refresh()
        Log.info("Verilerimi Sil tamamlandı", category: .flow)
        onBack()
    }

    private func performBlockCard() async {
        guard let cardId = SecureStore.getCardId(), !cardId.isEmpty else {
            infoMessage = L.t("error_no_blockable_card"); return
        }
        // Android: bloke isteği için bir history nonce'u kullanır (en güncel cardId'li kayıt).
        let nonce = HistoryRepository.shared
            .fetchAll(currentCardId: appState.currentCardId)
            .first(where: { !$0.cardId.isEmpty })?.nonce ?? UUID().uuidString
        isWorking = true
        defer { isWorking = false }
        do {
            try await VerifyAPI.shared.blockCard(KvkkBlockCardRequest(nonce: nonce, cardId: cardId))
            infoMessage = L.t("block_card_blocked")
        } catch let APIClientError.http(status, _) where status == 409 {
            infoMessage = L.t("block_card_already_blocked")
        } catch {
            infoMessage = L.t("block_card_error_prefix") + "\(error)"
        }
    }
}
