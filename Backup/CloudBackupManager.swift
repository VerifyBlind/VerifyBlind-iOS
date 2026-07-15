import Foundation

/// Bulut yedekleme orkestratörü — Android `backup/CloudBackupManager.kt` portu.
/// Sağlayıcı kaydı (Dropbox + Google Drive), seçili sağlayıcı + son yedek zamanı persist
/// (`AppPrefs`), connect/sync/disconnect. Asıl çift yönlü senkron `SyncManager`'dadır.
enum CloudBackupManager {
    static let backupFilename = "verifyblind_backup.json"

    private static var providers: [String: CloudProvider] = [:]

    // MARK: - Sağlayıcı kaydı

    /// `BackupBootstrap.configure()` çağırır.
    static func registerDefaults() {
        register(DropboxProvider.shared)
        register(GoogleDriveProvider.shared)
    }

    static func register(_ provider: CloudProvider) { providers[provider.id] = provider }
    static func provider(_ id: String) -> CloudProvider? { providers[id] }
    static func allProviders() -> [CloudProvider] { Array(providers.values) }

    // MARK: - Durum

    struct Status {
        let providerId: String?
        let lastBackupMs: Int64
        var isConnected: Bool { providerId != nil }
        var provider: CloudProvider? { providerId.flatMap { CloudBackupManager.provider($0) } }
    }

    static func status() -> Status {
        Status(providerId: AppPrefs.cloudProvider, lastBackupMs: AppPrefs.cloudLastBackup)
    }

    static func saveProviderChoice(_ id: String?) { AppPrefs.cloudProvider = id }

    static func saveLastBackupTimestamp() {
        AppPrefs.cloudLastBackup = Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - İşlemler

    /// Sağlayıcıya bağlan: OAuth login → seçimi kaydet → mevcut bulut yedeğini çekmek için ilk senkron.
    @MainActor
    static func connect(_ provider: CloudProvider) async throws -> SyncResult {
        try await provider.login()
        saveProviderChoice(provider.id)
        return await SyncManager.shared.performSync(provider: provider)
    }

    /// Seçili sağlayıcıyla şimdi eşitle.
    static func syncNow() async -> SyncResult {
        guard let provider = status().provider, provider.isLoggedIn() else {
            return SyncResult(error: "Önce bir bulut sağlayıcı seçin.")
        }
        return await SyncManager.shared.performSync(provider: provider)
    }

    /// Bağlantıyı kes (yerel; buluttaki dosya SİLİNMEZ). Android `disconnect`.
    static func disconnect() {
        status().provider?.logout()
        AppPrefs.clearCloud()
    }

    /// Buluttaki yedek dosyasını sil, sonra bağlantıyı kes. Android `disconnectAndDelete`.
    static func disconnectAndDelete() async {
        if let provider = status().provider {
            try? await provider.delete(filename: backupFilename)
        }
        disconnect()
    }
}
