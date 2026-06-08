import Foundation
import UIKit
import GoogleSignIn

/// Google Drive sağlayıcı — Android `backup/GoogleDriveProvider.kt` portu.
/// OAuth = **GoogleSignIn-iOS** (yalnız kimlik doğrulama + erişim token'ı); Drive işlemleri
/// `appDataFolder`'a karşı **elle URLSession REST** (ağır GoogleAPIClientForREST bağımlılık ağacı yok).
///
/// `appDataFolder` = uygulamaya özel gizli klasör (`drive.appdata` scope) → dosya kullanıcının
/// Drive arayüzünde GÖRÜNMEZ. Token GoogleSignIn'de saklanır (cihaz-yerel). Client ID
/// `Config.googleClientID` → `BackupBootstrap.configure()`.
final class GoogleDriveProvider: CloudProvider {
    static let shared = GoogleDriveProvider()

    let id = "google_drive"
    let displayName = "Google Drive"

    private static let driveScope = "https://www.googleapis.com/auth/drive.appdata"

    func isLoggedIn() -> Bool {
        GIDSignIn.sharedInstance.currentUser != nil
    }

    @MainActor
    func login() async throws {
        guard let controller = UIApplication.topViewController() else {
            throw CloudProviderError.presentationFailed
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: controller,
                hint: nil,
                additionalScopes: [Self.driveScope]
            ) { result, error in
                if result?.user != nil {
                    Log.info("Google Drive OAuth başarılı", category: .flow)
                    cont.resume()
                } else if let error = error {
                    cont.resume(throwing: Self.map(error))
                } else {
                    cont.resume(throwing: CloudProviderError.cancelled)
                }
            }
        }
    }

    func logout() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// `onOpenURL`'den çağrılır (Google OAuth redirect = reversed client id şeması).
    static func handleRedirect(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    private static func map(_ error: Error) -> CloudProviderError {
        if let gid = error as? GIDSignInError, gid.code == .canceled {
            return .cancelled
        }
        return .message((error as NSError).localizedDescription)
    }

    // MARK: - Erişim token'ı

    @MainActor
    private func freshAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw CloudProviderError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            user.refreshTokensIfNeeded { refreshed, error in
                if let refreshed = refreshed {
                    cont.resume(returning: refreshed.accessToken.tokenString)
                } else if let error = error {
                    cont.resume(throwing: Self.map(error))
                } else {
                    cont.resume(throwing: CloudProviderError.notAuthenticated)
                }
            }
        }
    }

    // MARK: - Drive REST (appDataFolder)

    @discardableResult
    private func authorizedRequest(_ url: URL, method: String,
                                   contentType: String? = nil, body: Data? = nil) async throws -> Data {
        let token = try await freshAccessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CloudProviderError.message("Drive: HTTP olmayan yanıt")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudProviderError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func findFileId(_ filename: String) async throws -> String? {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(filename)'"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        let data = try await authorizedRequest(comps.url!, method: "GET")
        struct ListResp: Decodable {
            struct F: Decodable { let id: String }
            let files: [F]
        }
        return try JSONDecoder().decode(ListResp.self, from: data).files.first?.id
    }

    func upload(filename: String, data: String) async throws {
        let content = Data(data.utf8)
        if let existingId = try await findFileId(filename) {
            // Var olanı medya güncelle (Android `files().update(id, null, content)`).
            let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existingId)?uploadType=media")!
            try await authorizedRequest(url, method: "PATCH", contentType: "application/json", body: content)
        } else {
            // appDataFolder içinde yeni oluştur (multipart: metadata + içerik).
            let boundary = "vb-\(UUID().uuidString)"
            let metadata = try JSONSerialization.data(withJSONObject: [
                "name": filename,
                "parents": ["appDataFolder"],
            ])
            var body = Data()
            func append(_ s: String) { body.append(Data(s.utf8)) }
            append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
            body.append(metadata)
            append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n")
            body.append(content)
            append("\r\n--\(boundary)--\r\n")
            let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!
            try await authorizedRequest(url, method: "POST",
                                        contentType: "multipart/related; boundary=\(boundary)", body: body)
        }
    }

    func download(filename: String) async throws -> String? {
        guard let id = try await findFileId(filename) else { return nil }  // dosya yok → nil
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        let data = try await authorizedRequest(url, method: "GET")
        return String(decoding: data, as: UTF8.self)
    }

    func delete(filename: String) async throws {
        guard let id = try await findFileId(filename) else { return }  // zaten yoktu
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        try await authorizedRequest(url, method: "DELETE")
    }
}
