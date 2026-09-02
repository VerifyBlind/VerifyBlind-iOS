import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Manuel Yedekle / Geri Yükle / Tümünü Sil ekranı — Android `BackupFragment` paritesi.
/// Sürekli senkron KALDIRILDI. Yedek = tek `.vfbackup`
/// snapshot; tüm dosya AES-256-GCM (parola → yerel PBKDF2). Konum: Google Drive / Dropbox / Dosya.
/// Sağlayıcı: SADECE Dropbox + Google Drive (iCloud YOK — ZKP).
///
/// Tip adı `BackupSettingsView` KORUNDU (sunan koordinatör `BackupSettingsView(onBack:)` çağırır).
struct BackupSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let onBack: () -> Void
    @StateObject private var vm = BackupViewModel()

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_backup_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)

            ScrollView {
                VStack(spacing: 12) {
                    Text(L.t("backup_screen_desc"))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)

                    PrimaryGradientButton(title: L.t("backup_action_export"), systemImage: "square.and.arrow.up",
                                          enabled: !vm.isBusy, height: 52, fontSize: 15) {
                        vm.showExportLocation = true
                    }

                    Button { vm.showRestoreLocation = true } label: {
                        CardSurface {
                            HStack(spacing: 16) {
                                IconCircle(systemName: "square.and.arrow.down", fill: Theme.cyanSoft, tint: Theme.chipCyan)
                                Text(L.t("backup_action_restore"))
                                    .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)

                    DangerButton(title: L.t("backup_action_delete_all")) {
                        vm.showDeleteAllConfirm = true
                    }

                    if vm.isBusy { ProgressView().padding(.top, 8) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
                // Şifreli dosya parolası — alert içinde SecureField (iOS 16). Mesaj alert'iyle çakışmasın
                // diye AYRI view'a (ScrollView) iliştirildi.
                .alert(L.t("restore_password_title"), isPresented: $vm.showRestorePassword) {
                    SecureField(L.t("backup_password_hint"), text: $vm.restorePassword)
                    Button(L.t("common_ok")) { vm.submitRestorePassword() }
                    Button(L.t("btn_cancel"), role: .cancel) {}
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        // Yedekle: konum seçimi
        .confirmationDialog(L.t("backup_export_title"), isPresented: $vm.showExportLocation, titleVisibility: .visible) {
            Button(L.t("backup_loc_gdrive")) { vm.chooseExport(.drive) }
            Button(L.t("backup_loc_dropbox")) { vm.chooseExport(.dropbox) }
            Button(L.t("backup_loc_file")) { vm.chooseExport(.file) }
            Button(L.t("btn_cancel"), role: .cancel) {}
        }
        // Geri Yükle: konum seçimi
        .confirmationDialog(L.t("backup_restore_title"), isPresented: $vm.showRestoreLocation, titleVisibility: .visible) {
            Button(L.t("backup_loc_gdrive")) { vm.listCloud(GoogleDriveProvider.shared) }
            Button(L.t("backup_loc_dropbox")) { vm.listCloud(DropboxProvider.shared) }
            Button(L.t("restore_loc_device")) { vm.showImporter = true }
            Button(L.t("btn_cancel"), role: .cancel) {}
        }
        // Buluttaki yedek dosyası seçimi
        .confirmationDialog(L.t("restore_pick_file"), isPresented: $vm.showFileList, titleVisibility: .visible) {
            ForEach(vm.cloudFiles, id: \.name) { f in
                Button(f.name) { vm.downloadAndImport(f.name) }
            }
            Button(L.t("btn_cancel"), role: .cancel) {}
        }
        // Tümünü Sil onayı
        .confirmationDialog(L.t("delete_all_title"), isPresented: $vm.showDeleteAllConfirm, titleVisibility: .visible) {
            Button(L.t("btn_delete_confirm"), role: .destructive) { vm.deleteAll() }
            Button(L.t("btn_cancel"), role: .cancel) {}
        } message: {
            Text(L.t("delete_all_message"))
        }
        // Şifreleme seçimi + parola
        .sheet(isPresented: $vm.showEncryptSheet) { encryptSheet }
        // "Dosya olarak kaydet": paylaşım sayfası (Dosyalar / AirDrop / WhatsApp …)
        .sheet(isPresented: $vm.showShare) {
            if let url = vm.shareURL { ActivityView(items: [url]) }
        }
        // Telefondaki dosyadan geri yükle
        .fileImporter(isPresented: $vm.showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): vm.readImportedFile(url)
            case .failure: vm.message = L.t("backup_read_failed")
            }
        }
        // Sonuç / hata mesajı
        .alert(vm.message ?? "", isPresented: Binding(
            get: { vm.message != nil }, set: { if !$0 { vm.message = nil } }
        )) {
            Button(L.t("common_ok"), role: .cancel) {}
        }
        // Bulut OAuth akışı boyunca otomatik kilidi bastır. Google/Dropbox oturum ekranı bir SİSTEM
        // sunumu olduğu için uygulamayı arka plana düşürüyor; kilit devreye girip dönüşte OAuth
        // ekranını kapatıyordu (cihazda ekran ~100 ms görünüp kayboluyordu). Kayıt/giriş akışları
        // bu bastırmayı zaten kullanıyor — yedekleme listeye alınmamıştı.
        .onChange(of: vm.cloudFlowActive) { active in
            appState.suppressAutoLock = active   // yedek; asıl yazma beginCloudFlow'da senkron
        }
        .onAppear { vm.appState = appState }
        // Ekran kapanırken bastırmayı BIRAK: akış ortasında geri gidilirse kilit kalıcı olarak
        // devre dışı kalmasın (güvenlik gevşemesi sızıntısı).
        .onDisappear { appState.suppressAutoLock = false }
    }

    // MARK: - Şifreleme sheet'i

    private var encryptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("backup_export_title"))
                .font(.system(size: 18, weight: .bold)).foregroundColor(Theme.onSurface)
                .padding(.top, 8)

            Toggle(L.t("backup_encrypt_checkbox"), isOn: $vm.encryptEnabled)
                .tint(Theme.themePrimary)

            if vm.encryptEnabled {
                SecureField(L.t("backup_password_hint"), text: $vm.exportPassword)
                    .textFieldStyle(.roundedBorder)
                Text(L.t("backup_password_warning"))
                    .font(.system(size: 12)).foregroundColor(.red)
            } else {
                Text(L.t("backup_plaintext_warning"))
                    .font(.system(size: 12)).foregroundColor(.red)
            }

            PrimaryGradientButton(title: L.t("backup_do_export"), systemImage: "square.and.arrow.up",
                                  enabled: !vm.isBusy, height: 52, fontSize: 15) {
                vm.confirmExport()
            }
            Button(L.t("btn_cancel")) { vm.showEncryptSheet = false }
                .frame(maxWidth: .infinity)
                .foregroundColor(Theme.onSurfaceVariant)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// UIActivityViewController SwiftUI sarmalayıcısı — "Dosya olarak kaydet"/paylaş için.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - ViewModel

enum BackupExportTarget { case drive, dropbox, file }

@MainActor
final class BackupViewModel: ObservableObject {

    /// Bulut (OAuth) akışı sürüyor mu — otomatik kilidi bastırmak için.
    ///
    /// Google/Dropbox oturum açma ekranı bir SİSTEM sunumu: açıldığında uygulama arka plana
    /// geçiyor ve `ContentView`'daki otomatik kilit devreye girip `locked = true` yapıyor.
    /// Dönüşte kilit/Face ID ekranı öne gelip OAuth ekranını KAPATIYOR — kullanıcı Google'ın
    /// izin sorusunu yaklaşık 100 ms görüp kayboluşunu izliyor (cihaz raporu 2026-08-26).
    ///
    /// Kayıt/giriş akışları bu bastırmayı zaten kullanıyordu (NFC/kamera/Face ID aynı sorunu
    /// yaratıyor); yedekleme o listeye alınmamıştı.
    @Published private(set) var cloudFlowActive = false

    /// İÇ İÇE kullanım sayacı: dışa aktarma akışı bastırmayı biyometrik kapıdan ÖNCE açıyor ve
    /// içeride `upload` tekrar açıyor. Düz bir Bool olsaydı içteki `defer` bastırmayı akış hâlâ
    /// sürerken kapatırdı.
    private var cloudFlowDepth = 0

    /// Bastırmayı DOĞRUDAN yazmak için. `@Published` + `.onChange` köprüsü SwiftUI'ın bir sonraki
    /// görünüm güncellemesinde çalışıyor; biyometrik kapı hemen ardından geldiği için uygulama
    /// güncelleme olmadan arka plana düşüyor ve bastırma HENÜZ yazılmamış oluyordu. Kilit
    /// kararının doğru anda alınması bir render döngüsüne bağlı olamaz.
    weak var appState: AppState?

    private func beginCloudFlow() {
        cloudFlowDepth += 1
        cloudFlowActive = true
        appState?.suppressAutoLock = true          // SENKRON — köprüyü bekleme
        Log.info("Bulut akışı BAŞLADI (derinlik=\(cloudFlowDepth)) — otomatik kilit bastırıldı", category: .flow)
    }

    private func endCloudFlow() {
        cloudFlowDepth = max(0, cloudFlowDepth - 1)
        if cloudFlowDepth == 0 {
            cloudFlowActive = false
            appState?.suppressAutoLock = false
            Log.info("Bulut akışı BİTTİ — bastırma kaldırıldı", category: .flow)
        }
    }
    @Published var isBusy = false
    @Published var message: String?

    // Yedekle
    @Published var showExportLocation = false
    @Published var showEncryptSheet = false
    @Published var encryptEnabled = true
    @Published var exportPassword = ""
    private var exportTarget: BackupExportTarget = .file

    // "Dosya olarak kaydet" paylaşımı
    @Published var showShare = false
    @Published var shareURL: URL?

    // Geri Yükle
    @Published var showRestoreLocation = false
    @Published var showImporter = false
    @Published var showFileList = false
    @Published var cloudFiles: [CloudFileEntry] = []
    private var restoreProvider: CloudProvider?

    // Şifreli dosya parolası
    @Published var showRestorePassword = false
    @Published var restorePassword = ""
    private var pendingRestoreJson: String?

    // Tümünü Sil
    @Published var showDeleteAllConfirm = false

    // MARK: Yedekle

    func chooseExport(_ target: BackupExportTarget) {
        exportTarget = target
        encryptEnabled = true
        exportPassword = ""
        showEncryptSheet = true
    }

    func confirmExport() {
        let encrypt = encryptEnabled
        let password = exportPassword
        if encrypt && password.count < 6 {
            message = L.t("backup_password_too_short")
            return
        }
        showEncryptSheet = false
        let target = exportTarget
        Task {
            // Bastırma BİYOMETRİK KAPIDAN ÖNCE açılır — kapının kendisi uygulamayı arka plana
            // düşürüyor. Bastırma yalnız yükleme adımını sarsaydı (ilk deneme böyleydi), PIN
            // ekranı sırasında `locked = true` olur, dönüşte `.active` tetiklenir, `unlock()`
            // bir kilit ekranı daha sunar ve OAuth ekranını kapatırdı. Cihazda görülen tam olarak
            // buydu: popup PIN'DEN SONRA çıkıp anında kayboluyordu (2026-08-27).
            beginCloudFlow()
            defer { endCloudFlow() }

            // Yedekleme geçmişi dışa aktarır → sahibi biyometrik doğrulasın (manuel eşitleme paritesi).
            do { try await BiometricGate.authenticate(reason: L.t("biometric_subtitle_decrypt")) }
            catch { return }

            isBusy = true
            defer { isBusy = false }
            let pw: String? = encrypt ? password : nil
            let json: String
            do {
                json = try await Task.detached(priority: .userInitiated) {
                    let records = BackupManager.collectRecords()
                    return try BackupFile.write(records: records, password: pw)
                }.value
            } catch {
                message = L.t("backup_save_failed")
                return
            }

            switch target {
            case .drive:   await upload(GoogleDriveProvider.shared, json)
            case .dropbox: await upload(DropboxProvider.shared, json)
            case .file:    presentShare(json)
            }
        }
    }


    /// Bulut hatasını KAYDET, sonra kullanıcıya yerelleştirilmiş mesajı göster.
    ///
    /// Eskiden her yerde `catch { message = ... }` vardı ve hata nesnesi hiç okunmuyordu:
    /// kullanıcı "başarısız" görüyor, bizde tek satır iz kalmıyordu. 2026-08-25'te Google Drive
    /// yedeklemesi tam olarak böyle başarısız oldu — Sentry'de hiçbir kayıt yoktu ve cihaz elde
    /// olmadan nedenini bulmanın yolu da yoktu. `CloudProviderError` zaten okunabilir bir
    /// `description` üretiyor (http kodu, OAuth durumu, yapılandırma eksikliği); sorun onu kimsenin
    /// okumamasıydı.
    ///
    /// `.cancelled` LOGLANMAZ: kullanıcının OAuth ekranını kapatması arıza değildir ve Sentry
    /// kotasını gürültüyle doldurur.
    private func logCloudFailure(_ operation: String, _ providerId: String, _ error: Error) {
        if case CloudProviderError.cancelled = error { return }
        // http gövdesi uzun olabilir → kırp. Google hata gövdeleri token içermez ama yine de
        // sınırlı tutuyoruz (log hijyeni).
        let detail = String(describing: error).prefix(300)
        Log.warning("Bulut yedekleme başarısız [\(operation)/\(providerId)]: \(detail)", category: .flow)
    }

    private func upload(_ provider: CloudProvider, _ json: String) async {
        beginCloudFlow()
        defer { endCloudFlow() }
        do {
            if !provider.isLoggedIn() { try await provider.login() }
            try await provider.upload(filename: BackupNaming.defaultFileName(), data: json)
            message = L.t("backup_upload_success")
        } catch CloudProviderError.cancelled {
            // sessiz
        } catch {
            logCloudFailure("upload", provider.id, error)
            message = L.t("backup_upload_failed")
        }
    }

    private func presentShare(_ json: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(BackupNaming.defaultFileName())
        do {
            try Data(json.utf8).write(to: url)
            shareURL = url
            showShare = true
        } catch {
            message = L.t("backup_save_failed")
        }
    }

    // MARK: Geri Yükle

    func listCloud(_ provider: CloudProvider) {
        Task {
            isBusy = true
            beginCloudFlow()
            defer { isBusy = false; endCloudFlow() }
            do {
                if !provider.isLoggedIn() { try await provider.login() }
                let files = try await provider.list(suffix: BackupNaming.ext)
                if files.isEmpty {
                    message = L.t("restore_no_files")
                    return
                }
                cloudFiles = files
                restoreProvider = provider
                showFileList = true
            } catch CloudProviderError.cancelled {
            } catch {
                logCloudFailure("list", provider.id, error)
                message = L.t("backup_read_failed")
            }
        }
    }

    func downloadAndImport(_ filename: String) {
        guard let provider = restoreProvider else { return }
        Task {
            isBusy = true
            beginCloudFlow()
            defer { isBusy = false; endCloudFlow() }
            do {
                guard let json = try await provider.download(filename: filename) else {
                    message = L.t("backup_read_failed")
                    return
                }
                importJson(json)
            } catch {
                logCloudFailure("download", provider.id, error)
                message = L.t("backup_read_failed")
            }
        }
    }

    func readImportedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            importJson(String(decoding: data, as: UTF8.self))
        } catch {
            message = L.t("backup_read_failed")
        }
    }

    private func importJson(_ json: String) {
        let encrypted: Bool
        do { encrypted = try BackupFile.inspect(json: json).encrypted }
        catch { message = L.t("backup_invalid_file"); return }

        if encrypted {
            pendingRestoreJson = json
            restorePassword = ""
            showRestorePassword = true
        } else {
            runImport(json, password: nil)
        }
    }

    func submitRestorePassword() {
        guard let json = pendingRestoreJson else { return }
        runImport(json, password: restorePassword)
    }

    private func runImport(_ json: String, password: String?) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> BackupManager.ImportResult in
                    let records = try BackupFile.read(json: json, password: password)
                    return try BackupManager.importRecords(HistoryRepository.shared, records)
                }.value
                message = String(format: L.t("restore_result"), result.added, result.skipped)
            } catch BackupPasswordError.wrongPassword {
                message = L.t("restore_wrong_password")
                pendingRestoreJson = json
                restorePassword = ""
                showRestorePassword = true
            } catch {
                message = L.t("backup_invalid_file")
            }
        }
    }

    // MARK: Tümünü Sil

    /// Yerel geçmişi SERT siler (Android `BackupFragment.confirmDeleteAll` paritesi). Başarısızlık
    /// artık sessizce yutulmuyor — eskiden yazma hatası loglanıp kullanıcıya yine "Tüm geçmiş
    /// silindi" deniyordu, yani ekranda duran kayıtlarla mesaj çelişebiliyordu.
    func deleteAll() {
        do {
            try HistoryRepository.shared.deleteAll()
            message = L.t("delete_all_done")
        } catch {
            Log.error("HistoryRepository.deleteAll başarısız", error: error, category: .flow)
            message = L.t("operation_failed_title")
        }
    }
}
