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

    /// Oturum VAR MI değil, **Drive izni verilmiş bir oturum var mı**.
    ///
    /// Yalnız `currentUser != nil` bakmak yetmiyordu: GoogleSignIn önceki oturumu Keychain'den geri
    /// yüklüyor ve o oturum Drive kapsamı OLMADAN açılmışsa (ör. yalnız kimlik için giriş yapılmış
    /// bir geçmiş), `isLoggedIn()` true dönüyor, çağıran taraf `login()`'i hiç çalıştırmıyor ve
    /// token Drive iznini asla almıyor. Yükleme o zaman 403 "insufficient authentication scopes"
    /// ile düşüyor — cihazda 2026-08-25'te tam olarak bu görüldü.
    ///
    /// Kapsamı burada kontrol etmek, eksik izni bir sonraki denemede kendiliğinden onarır:
    /// `login()` çalışır ve Google eksik kapsamı ister.
    func isLoggedIn() -> Bool {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return false }
        return user.grantedScopes?.contains(Self.driveScope) == true
    }

    @MainActor
    func login() async throws {
        // Configuration (clientID) set edilmemişse GIDSignIn.signIn ÇÖKER (NSException). Önce kibarca hata ver.
        guard GIDSignIn.sharedInstance.configuration != nil else {
            throw CloudProviderError.message("Google Drive yapılandırılmamış (GOOGLE_IOS_CLIENT_ID eksik).")
        }
        // Geçiş bitene kadar BEKLE. Parola sheet'inin kapanışı ve biyometrik kapı arka arkaya
        // geçiş üretiyor; bunların ortasında sunulan OAuth ekranı, kapanan controller'la birlikte
        // anında yok oluyordu (~100 ms görünüp kayboluyordu).
        guard let controller = await UIApplication.settledTopViewController() else {
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

    /// Kimlik/izin hatasında YEREL oturumu kapatır — Android `clearSignInIfAuthError` paritesi.
    ///
    /// `isLoggedIn()` verilmiş kapsamı kontrol ediyor, ama kapsam SONRADAN geri alınabiliyor
    /// (kullanıcı myaccount.google.com'dan erişimi kaldırır) ya da token geçersizleşiyor. O
    /// durumda oturumu kapatmazsak `isLoggedIn()` true kalır, çağıran taraf `login()`'i hiç
    /// çalıştırmaz ve kullanıcı izin ekranını uygulamayı silmeden bir daha göremez.
    ///
    /// Yalnız kimlik/izin hataları — hız sınırı/kota gibi geçici 403'ler değil.
    private static func clearSignInIfAuthError(status: Int, body: String) {
        let isAuthError = status == 401
            || (status == 403 && (body.contains("insufficientPermissions")
                                  || body.contains("insufficient authentication scopes")
                                  || body.contains("forbidden")))
        guard isAuthError else { return }
        Log.warning("Drive yetkisi geçersiz -> yerel oturum kapatıldı, sonraki denemede izin yeniden istenecek", category: .flow)
        Task { @MainActor in shared.logout() }
    }

    /// `onOpenURL`'den çağrılır (Google OAuth redirect = reversed client id şeması).
    static func handleRedirect(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    private static func map(_ error: Error) -> CloudProviderError {
        // GIDSignInErrorCode.canceled = -5. Tip-bağımsız (bridging belirsizliği yok) NSError kontrolü.
        let ns = error as NSError
        if ns.domain == "com.google.GIDSignIn" && ns.code == -5 {
            return .cancelled
        }
        // Taşıma hatasında sistemin ham metni yerine kanonik "bağlantını kontrol et" mesajı:
        // kullanıcı internetsizken "The Internet connection appears to be offline." görüyordu.
        if NetworkStatus.isTransportFailure(error) {
            return .message(L.t("error_connection_generic"))
        }
        return .message(ns.localizedDescription)
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
            let body = String(decoding: data, as: UTF8.self)
            Self.clearSignInIfAuthError(status: http.statusCode, body: body)
            throw CloudProviderError.http(http.statusCode, body)
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

    func list(suffix: String) async throws -> [CloudFileEntry] {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name contains '\(suffix)' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,modifiedTime)"),
            URLQueryItem(name: "pageSize", value: "100"),
        ]
        let data = try await authorizedRequest(comps.url!, method: "GET")
        struct ListResp: Decodable {
            struct F: Decodable { let name: String; let modifiedTime: String? }
            let files: [F]
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONDecoder().decode(ListResp.self, from: data).files
            .filter { $0.name.lowercased().hasSuffix(suffix.lowercased()) }
            .map { f -> CloudFileEntry in
                let ms = f.modifiedTime.flatMap { iso.date(from: $0) }
                    .map { Int64($0.timeIntervalSince1970 * 1000) }
                return CloudFileEntry(name: f.name, modifiedAtMillis: ms)
            }
            .sorted { ($0.modifiedAtMillis ?? 0) > ($1.modifiedAtMillis ?? 0) }
    }
}
