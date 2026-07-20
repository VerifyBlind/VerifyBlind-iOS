import SwiftUI

/// Şifreli bulut yedekleme ayarları (Aşama 5) — Android `SettingsFragment` yedekleme bölümü paritesi.
/// Sağlayıcı: SADECE **Dropbox + Google Drive** (iCloud YOK — ZKP, [[project_ios_backup_zkp_hardening]]).
/// Bağlan → mevcut yedeği çeker (ilk senkron); "Şimdi Eşitle" çift yönlü senkron; "Bağlantıyı Kes".
struct BackupSettingsView: View {
    let onBack: () -> Void
    @StateObject private var vm = BackupSettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_backup_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(spacing: 12) {
                    // Açıklama
                    Text(L.t("settings_backup_desc"))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if vm.status.isConnected {
                        connectedSection
                    } else {
                        providerSelectionSection
                    }

                    if vm.isBusy {
                        ProgressView().padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { vm.refresh() }
        .alert(L.t("disconnect_confirm_title"), isPresented: $vm.showDisconnectConfirm) {
            Button(L.t("disconnect_confirm_button"), role: .destructive) { vm.disconnect() }
            Button(L.t("btn_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("disconnect_confirm_message"))
        }
        // Yedek silme onayı: rıza sonucunu açıkça söyler (geri çekme geçmiş kayıtları üzerinden
        // yapılır; geçmiş silinirse tek yol hizmet sağlayıcıya doğrudan başvurmak). Varsayılan
        // "Vazgeç" → kullanıcı uyarıyı görüp geri dönebilsin.
        .alert(L.t("backup_delete_confirm_title"), isPresented: $vm.showDeleteBackupConfirm) {
            Button(L.t("backup_delete_confirm_button"), role: .destructive) { vm.deleteCloudBackup() }
            Button(L.t("btn_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("backup_delete_confirm_message"))
        }
        .alert(vm.alertMessage ?? "", isPresented: Binding(
            get: { vm.alertMessage != nil },
            set: { if !$0 { vm.alertMessage = nil } }
        )) {
            Button(L.t("common_ok"), role: .cancel) {}
        }
    }

    // MARK: - Bağlı

    private var connectedSection: some View {
        VStack(spacing: 12) {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: "checkmark.icloud", fill: Theme.blueSoft, tint: Theme.themePrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.status.provider?.displayName ?? "—")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                        Text(vm.lastBackupText)
                            .font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                    }
                    Spacer()
                }
            }

            PrimaryGradientButton(title: L.t("backup_sync_now"), systemImage: "arrow.triangle.2.circlepath",
                                  enabled: !vm.isBusy, height: 52, fontSize: 15) {
                vm.syncNow()
            }

            DangerButton(title: L.t("backup_disconnect")) {
                vm.showDisconnectConfirm = true
            }

            // Bulut yedeğini KALICI sil. Ayrı bir eylem: "Bağlantıyı Kes" dosyaya dokunmaz.
            // Google Drive yedeği appDataFolder'da durur ve Drive arayüzünde GÖRÜNMEZ → bu eylem
            // olmadan kullanıcı yedeğini hiçbir şekilde silemez (silme hakkı fiilen kullanılamaz).
            DangerButton(title: L.t("backup_delete_cloud")) {
                vm.showDeleteBackupConfirm = true
            }
        }
    }

    // MARK: - Sağlayıcı seçimi

    private var providerSelectionSection: some View {
        VStack(spacing: 12) {
            Text(L.t("backup_provider_title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            providerRow(provider: DropboxProvider.shared, systemName: "shippingbox", fill: Theme.blueSoft, tint: Theme.themePrimary)
            providerRow(provider: GoogleDriveProvider.shared, systemName: "externaldrive.badge.icloud", fill: Theme.cyanSoft, tint: Theme.chipCyan)
        }
    }

    private func providerRow(provider: CloudProvider, systemName: String, fill: Color, tint: Color) -> some View {
        Button { vm.connect(provider) } label: {
            CardSurface {
                HStack(spacing: 16) {
                    IconCircle(systemName: systemName, fill: fill, tint: tint)
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
    }
}

/// Yedekleme ekranı durum yönetimi — connect/sync/disconnect, busy + alert.
@MainActor
final class BackupSettingsViewModel: ObservableObject {
    @Published var status = CloudBackupManager.status()
    @Published var isBusy = false
    @Published var alertMessage: String?
    @Published var showDisconnectConfirm = false
    @Published var showDeleteBackupConfirm = false

    var lastBackupText: String {
        guard status.lastBackupMs > 0 else { return L.t("backup_not_yet") }
        let date = Date(timeIntervalSince1970: Double(status.lastBackupMs) / 1000)
        return L.t("backup_last_prefix") + Self.dateFormatter.string(from: date)
    }

    func refresh() { status = CloudBackupManager.status() }

    func connect(_ provider: CloudProvider) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await CloudBackupManager.connect(provider)
                refresh()
                if let error = result.error {
                    alertMessage = L.t("sync_error_title") + "\n" + error
                } else {
                    alertMessage = provider.id == GoogleDriveProvider.shared.id
                        ? L.t("cloud_backup_success_gdrive")
                        : L.t("cloud_backup_success_dropbox")
                }
            } catch CloudProviderError.cancelled {
                // Kullanıcı iptal etti — uyarı gösterme.
            } catch {
                alertMessage = L.t("cloud_login_failed_message") + "\(error)"
            }
        }
    }

    func syncNow() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }

            // Biyometrik kapı (Android `SettingsFragment.performSync` paritesi): manuel eşitleme
            // işlem geçmişini buluta yazar → önce cihaz sahibi doğrulanır.
            do {
                try await BiometricGate.authenticate(reason: L.t("biometric_subtitle_decrypt"))
            } catch {
                alertMessage = L.t("sync_auth_failed_prefix") + error.localizedDescription
                return
            }

            let result = await CloudBackupManager.syncNow()
            refresh()
            if let error = result.error {
                alertMessage = L.t("sync_error_title") + "\n" + error
            } else if result.hasChanges {
                // Sayaçlar Android paritesi: kullanıcı neyin değiştiğini görür ("tamamlandı" tek
                // başına sessiz kalıyordu). SyncResult bu alanları zaten taşıyordu.
                alertMessage = L.t("sync_complete_changes")
                    + " (+\(result.itemsAdded) -\(result.itemsDeleted) ↑\(result.itemsUploaded))"
            } else {
                alertMessage = L.t("sync_already_current")
            }
        }
    }

    func disconnect() {
        CloudBackupManager.disconnect()
        refresh()
        alertMessage = L.t("disconnected_toast")
    }

    /// Buluttaki yedek dosyasını KALICI siler, sonra bağlantıyı keser (Android
    /// `CloudBackupManager.disconnectAndDelete` paritesi). Ağ gerektirir → isBusy ile korunur.
    func deleteCloudBackup() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            let deleted = await CloudBackupManager.disconnectAndDelete()
            isBusy = false
            refresh()
            // Başarısızlıkta "silindi" DEME — dosya hâlâ bulutta ve bağlantı korundu, tekrar denenebilir.
            alertMessage = deleted ? L.t("backup_delete_success") : L.t("backup_delete_failed")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
