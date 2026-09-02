import Foundation

/// Build-time injected configuration values.
///
/// Akış: CI ortam değişkenleri → xcconfig → Info.plist (`INFOPLIST_KEY_*` prefix sayesinde otomatik)
/// → `Bundle.main.object(forInfoDictionaryKey:)`. Production build'de değerler hardcoded değil;
/// her zaman CI ortamından (dev/prod ayrı) gelir.
enum Config {
    enum AppAttestEnvironment: String {
        case development
        case production
    }

    static let apiBaseURL: URL = {
        let raw = string("API_BASE_URL")
        guard let url = URL(string: raw) else {
            // Çökmeden önce Sentry'e açıklayıcı mesajı gönderir (düz fatalError'da bu metin rapora girmez).
            Log.fatal("Config: API_BASE_URL geçersiz veya eksik. xcconfig dosyasını kontrol edin.", category: .app)
        }
        return url
    }()

    // Cert pinning YOK (kasıtlı, 2026-07-08): api.verifyblind.com Cloudflare-proxied, edge sertifikasını
    // Cloudflare yönetir ve CA'yı habersiz değiştirebilir (Let's Encrypt/GTS/Sectigo — hepsi görüldü).
    // Cloudflare pinlemeyi desteklemiyor (HPKP kaldırıldı), OWASP de bu koşullarda önermiyor. TLS
    // platform varsayılanına bırakılır; CA değişimi sunucu tarafında izlenir (bloklamaz, alarm verir).

    /// Enclave PCR0 imzalarını doğrulamak için kullanılan RSA public key (base64 SPKI).
    static let enclaveDeveloperPublicKey: String = string("ENCLAVE_DEVELOPER_PUBLIC_KEY")

    static let appAttestEnvironment: AppAttestEnvironment = {
        let raw = string("APP_ATTEST_ENVIRONMENT")
        return AppAttestEnvironment(rawValue: raw) ?? .development
    }()

    // iCloud KALDIRILDI (Aşama 5, ZKP): yedekleme yalnız Dropbox + Google Drive.

    static let sentryDSN: String = string("SENTRY_DSN")

    static let dropboxAppKey: String = string("DROPBOX_IOS_APP_KEY")

    /// Google Sign-In OAuth client id (Aşama 5 yedekleme). Boşsa Google Drive devre dışı.
    static let googleClientID: String = string("GOOGLE_IOS_CLIENT_ID")

    /// CI'da gömülen kaynak commit SHA'sı (boş = lokal build). Ayarlar'daki sürüm satırında gösterilir;
    /// kod şeffaflığı zincirinin (GitHub Release build-N + Sigstore provenance) cihaz tarafı ucu.
    static let gitCommit: String = string("GIT_COMMIT")

    /// Sunucu `store_url_ios`'u boş bırakırsa (APPLE_STORE_URL env'i tanımsız) zorunlu güncelleme
    /// butonunun açacağı adres. Build-time enjekte DEĞİL, bilinçli sabit: env eksikliği kullanıcıyı
    /// mağazasız bırakmamalı. Sunucudaki `store_url` PLAY adresidir, buraya asla düşülmez.
    static let appStoreFallbackUrl = "https://apps.apple.com/app/verifyblind/id6776778178"

    /// Zorunlu güncelleme butonunun açacağı adresi seçer. Saf fonksiyon: `AppState` (@MainActor) ve
    /// self-test (nonisolated) aynı kararı paylaşsın, ikisi ayrı ayrı doğru olmaya çalışmasın.
    static func appStoreUrl(serverProvided: String?) -> String {
        let trimmed = (serverProvided ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appStoreFallbackUrl : trimmed
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // NOT: Demo modu görünürlüğü artık `Config.isTestFlight` ile DEĞİL, sunucu-kontrollü sürüm
    // eşleşmesiyle belirlenir: admin `demoVersionIos` == cihaz build sürümü (bkz AppState.loadConfig,
    // ConfigController app-config). Eski receipt-bazlı `isTestFlight` (kullanılmıyordu) kaldırıldı.

    private static func string(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value
    }
}
