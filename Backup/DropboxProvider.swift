import Foundation
import UIKit
import SwiftyDropbox

/// Dropbox sağlayıcı — Android `backup/DropboxProvider.kt` (SDK PKCE OAuth) iOS portu (SwiftyDropbox).
/// Dosya kök dizinde `/verifyblind_backup.json`, OVERWRITE. Token'lar SwiftyDropbox tarafından
/// Keychain'de saklanır (cihaz-yerel). App key `Config.dropboxAppKey` → `BackupBootstrap.configure()`.
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
        DropboxClientsManager.authorizedClient != nil
    }

    @MainActor
    func login() async throws {
        guard let controller = UIApplication.topViewController() else {
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
        DropboxClientsManager.unlinkClients()
    }

    // MARK: - Dosya işlemleri

    private func client() throws -> DropboxClient {
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
                            cont.resume(throwing: CloudProviderError.message("Dropbox delete: \(error.description)"))
                        }
                    } else {
                        cont.resume()
                    }
                }
        }
    }
}
