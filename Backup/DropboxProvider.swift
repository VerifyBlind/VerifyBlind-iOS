import Foundation
import UIKit
import SwiftyDropbox

/// Dropbox sağlayıcı — Android `backup/DropboxProvider.kt` (SDK PKCE OAuth) iOS portu (SwiftyDropbox).
/// Dosya kök dizinde `/verifyblind_backup.json`, OVERWRITE. Token'lar SwiftyDropbox tarafından
/// Keychain'de saklanır (cihaz-yerel). App key `Config.dropboxAppKey` → SDK kurulumu ilk
/// kullanımda `BackupBootstrap.ensureDropboxConfigured()` ile yapılır (açılışta değil).
///
/// OAuth sonucu uygulamaya `db-<appkey>://` redirect ile döner; `BackupBootstrap`/`onOpenURL`
/// `handleRedirect(_:)`'i çağırır → bekleyen `login()` continuation'ı tamamlanır (Android
/// `checkForAuthResult` paritesi).
final class DropboxProvider: CloudProvider {
    static let shared = DropboxProvider()

    let id = "dropbox"
    let displayName = "Dropbox"

    private var loginContinuation: CheckedContinuation<Void, Error>?

    func isLoggedIn() -> Bool {
        BackupBootstrap.ensureDropboxConfigured()
        return DropboxClientsManager.authorizedClient != nil
    }

    @MainActor
    func login() async throws {
        // Kurulum yapılmadan authorizeFromControllerV2 ÇÖKER; app key yoksa kibarca hata ver.
        guard BackupBootstrap.ensureDropboxConfigured() else {
            throw CloudProviderError.message("Dropbox yapılandırılmamış (DROPBOX_IOS_APP_KEY eksik).")
        }
        // Geçiş bitene kadar BEKLE. Parola sheet'inin kapanışı ve biyometrik kapı arka arkaya
        // geçiş üretiyor; bunların ortasında sunulan OAuth ekranı, kapanan controller'la birlikte
        // anında yok oluyordu (~100 ms görünüp kayboluyordu).
        guard let controller = await UIApplication.settledTopViewController() else {
            throw CloudProviderError.presentationFailed
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Aynı anda tek login; önceki bekleyen varsa iptal et.
            loginContinuation?.resume(throwing: CloudProviderError.cancelled)
            loginContinuation = cont
            let scopeRequest = ScopeRequest(
                scopeType: .user,
                scopes: ["files.content.write", "files.content.read"],
                includeGrantedScopes: false
            )
            DropboxClientsManager.authorizeFromControllerV2(
                UIApplication.shared,
                controller: controller,
                loadingStatusDelegate: nil,
                openURL: { url in UIApplication.shared.open(url) },
                scopeRequest: scopeRequest
            )
        }
    }

    /// `onOpenURL`'den çağrılır. URL bu sağlayıcıya aitse işler ve true döner.
    static func handleRedirect(_ url: URL) -> Bool {
        guard url.scheme?.hasPrefix("db-") == true else { return false }
        // Soğuk açılışta redirect kurulumdan önce gelebilir. Şema eşleştikten SONRA kurulum →
        // Keychain maliyeti yalnız gerçek Dropbox redirect'inde ödenir.
        guard BackupBootstrap.ensureDropboxConfigured() else { return false }
        // SwiftyDropbox 10.x: handleRedirectURL(_:completion:) overload'u YOK; foreground için
        // includeBackgroundClient zorunlu. Arka plan client kullanmıyoruz (setupWithAppKey default false).
        _ = DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { result in
            shared.finishLogin(result)
        }
        return true
    }

    private func finishLogin(_ result: DropboxOAuthResult?) {
        let cont = loginContinuation
        loginContinuation = nil
        guard let result else {
            cont?.resume(throwing: CloudProviderError.cancelled)
            return
        }
        switch result {
        case .success:
            Log.info("Dropbox OAuth başarılı", category: .flow)
            cont?.resume()
        case .cancel:
            cont?.resume(throwing: CloudProviderError.cancelled)
        case .error(_, let desc):
            cont?.resume(throwing: CloudProviderError.message(desc ?? "Dropbox OAuth hatası"))
        @unknown default:
            cont?.resume(throwing: CloudProviderError.cancelled)
        }
    }

    func logout() {
        BackupBootstrap.ensureDropboxConfigured()
        DropboxClientsManager.unlinkClients()
    }

    /// Token iptal/geçersiz ise saklanan istemciyi çözer — Android `clearCredentialIfAuthError` paritesi.
    ///
    /// Dropbox'ın izin ekranında Google'daki gibi kapsam kutucuğu YOK (ya hepsi ya iptal), yani
    /// "eksik izinle giriş" olamaz. Ama aynı KİLİT buraya da uyuyor: kullanıcı erişimi
    /// dropbox.com'dan geri alırsa token geçersizleşir, `isLoggedIn()` saklanan istemci yüzünden
    /// sonsuza dek true kalır, çağıran taraf `login()`'i bir daha çalıştırmaz ve kullanıcı
    /// yeniden yetkilendirme ekranını uygulamayı silmeden göremez.
    ///
    /// SwiftyDropbox hata tipleri jenerik (`CallError<T>`); bu dosyanın geri kalanı gibi
    /// tip-bağımsız açıklama eşlemesi kullanıyoruz.
    private static func unlinkIfAuthError(_ description: String) {
        guard description.contains("authError")
            || description.contains("invalid_access_token")
            || description.contains("expired_access_token") else { return }
        Log.warning("Dropbox token geçersiz -> istemci çözüldü, sonraki denemede yeniden yetkilendirme istenecek", category: .flow)
        DropboxClientsManager.unlinkClients()
    }

    // MARK: - Dosya işlemleri

    private func client() throws -> DropboxClient {
        BackupBootstrap.ensureDropboxConfigured()
        guard let c = DropboxClientsManager.authorizedClient else {
            throw CloudProviderError.notAuthenticated
        }
        return c
    }

    func upload(filename: String, data: String) async throws {
        let client = try client()
        let bytes = Data(data.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _ = client.files.upload(path: "/\(filename)", mode: .overwrite, autorename: false, mute: true, input: bytes)
                .response { _, error in
                    if let error = error {
                        Self.unlinkIfAuthError(error.description)
                        cont.resume(throwing: CloudProviderError.message("Dropbox upload: \(error.description)"))
                    } else {
                        cont.resume()
                    }
                }
        }
    }

    func download(filename: String) async throws -> String? {
        let client = try client()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            _ = client.files.download(path: "/\(filename)")
                .response { response, error in
                    if let response = response {
                        cont.resume(returning: String(decoding: response.1, as: UTF8.self))
                    } else if let error = error {
                        // Dosya yok → nil (hata değil). Tip-bağımsız olması için açıklama eşlemesi.
                        if error.description.contains("not_found") || error.description.contains("path/not_found") {
                            cont.resume(returning: nil)
                        } else {
                            Self.unlinkIfAuthError(error.description)
                            cont.resume(throwing: CloudProviderError.message("Dropbox download: \(error.description)"))
                        }
                    } else {
                        cont.resume(returning: nil)
                    }
                }
        }
    }

    func delete(filename: String) async throws {
        let client = try client()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _ = client.files.deleteV2(path: "/\(filename)")
                .response { _, error in
                    if let error = error {
                        if error.description.contains("not_found") || error.description.contains("path_lookup") {
                            cont.resume()   // zaten yoktu
                        } else {
                            Self.unlinkIfAuthError(error.description)
                            cont.resume(throwing: CloudProviderError.message("Dropbox delete: \(error.description)"))
                        }
                    } else {
                        cont.resume()
                    }
                }
        }
    }

    func list(suffix: String) async throws -> [CloudFileEntry] {
        let client = try client()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CloudFileEntry], Error>) in
            _ = client.files.listFolder(path: "")   // app-scoped kök
                .response { result, error in
                    if let result = result {
                        let entries = result.entries
                            .compactMap { $0 as? Files.FileMetadata }
                            .filter { $0.name.lowercased().hasSuffix(suffix.lowercased()) }
                            .map { CloudFileEntry(name: $0.name,
                                                  modifiedAtMillis: Int64($0.serverModified.timeIntervalSince1970 * 1000)) }
                            .sorted { ($0.modifiedAtMillis ?? 0) > ($1.modifiedAtMillis ?? 0) }
                        cont.resume(returning: entries)
                    } else if let error = error {
                        // Kök henüz yok (hiç yükleme yapılmamış) → boş liste, hata değil.
                        if error.description.contains("not_found") {
                            cont.resume(returning: [])
                        } else {
                            Self.unlinkIfAuthError(error.description)
                            cont.resume(throwing: CloudProviderError.message("Dropbox list: \(error.description)"))
                        }
                    } else {
                        cont.resume(returning: [])
                    }
                }
        }
    }
}
