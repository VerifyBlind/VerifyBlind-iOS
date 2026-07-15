import Foundation

/// Bulut depolama sağlayıcısı soyutlaması — Android `backup/CloudProvider.kt` portu.
/// Her implementasyon kendi OAuth login + dosya upload/download/delete'ini yönetir.
/// Yalnız uygulamanın izin verdiği sağlayıcılar: **Dropbox + Google Drive** (iCloud YOK — ZKP).
///
/// Android `Result<T>` yerine Swift `throws` + `async`. `login()` OAuth UI sunar → `@MainActor`.
protocol CloudProvider {

    /// Benzersiz anahtar (örn. "google_drive", "dropbox") — kalıcı sağlayıcı seçimi bunu saklar.
    var id: String { get }

    /// UI görünen ad (örn. "Google Drive").
    var displayName: String { get }

    /// Kullanıcı şu an kimlik doğrulamış mı (token mevcut mu).
    func isLoggedIn() -> Bool

    /// OAuth login akışını başlat (gerekirse harici tarayıcı/ASWebAuthenticationSession).
    /// Sunum için en üstteki view controller'ı kendisi bulur. Başarısızlıkta throw.
    @MainActor func login() async throws

    /// Token'ları temizle (yerel; ağ çağrısı yok).
    func logout()

    /// Buluta yükle (varsa üzerine yaz). `data` UTF-8 string içerik.
    func upload(filename: String, data: String) async throws

    /// Buluttan oku. Dosya yoksa `nil` döner (hata DEĞİL). Ağ/oturum hatasında throw.
    func download(filename: String) async throws -> String?

    /// Buluttan sil. Dosya yoktu ise yine başarı (throw etmez).
    func delete(filename: String) async throws
}

enum CloudProviderError: Error, CustomStringConvertible {
    case notAuthenticated
    case presentationFailed
    case cancelled
    case http(Int, String)
    case message(String)

    var description: String {
        switch self {
        case .notAuthenticated:   return "notAuthenticated"
        case .presentationFailed: return "presentationFailed"
        case .cancelled:          return "cancelled"
        case .http(let c, let m): return "http(\(c): \(m))"
        case .message(let m):     return m
        }
    }
    var localizedDescription: String { description }
}
