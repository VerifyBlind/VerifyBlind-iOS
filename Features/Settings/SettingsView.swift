import SwiftUI

/// Ayarlar — Aşama 4 minimal hub (Biyometrik Kilit + İşlem Geçmişi girişi). Tam Settings (Yardım,
/// Güvenlik, Yedekleme, Kart Engelle, Sıfırla, Dil) Aşama 6. Android `fragment_settings.xml` kart stili.
struct SettingsView: View {
    let onBack: () -> Void
    let onHistory: () -> Void
    let onBackup: () -> Void

    @State private var biometricEnabled = AppPrefs.biometricEnabled

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(spacing: 8) {
                    // Biyometrik kilit (pref saklanır; uygulama-açılış kilidi Aşama 6)
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

                    // İşlem Geçmişi
                    Button(action: onHistory) {
                        CardSurface {
                            HStack(spacing: 16) {
                                IconCircle(systemName: "clock.arrow.circlepath", fill: Theme.cyanSoft, tint: Theme.chipCyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L.t("settings_history_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                                    Text(L.t("settings_history_desc")).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Şifreli Yedekleme (Aşama 5 — Dropbox + Google Drive, iCloud YOK)
                    Button(action: onBackup) {
                        CardSurface {
                            HStack(spacing: 16) {
                                IconCircle(systemName: "lock.icloud", fill: Theme.blueSoft, tint: Theme.themePrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L.t("settings_backup_title")).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                                    Text(L.t("settings_backup_desc")).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
