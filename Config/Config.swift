import Foundation

/// Build-time injected configuration values.
///
/// Akış: CodeMagic env vars → xcconfig → Info.plist (`INFOPLIST_KEY_*` prefix sayesinde otomatik) →
/// `Bundle.main.object(forInfoDictionaryKey:)`. Production build'de değerler hardcoded değil; her zaman
/// `verifyblind_ios_dev`/`verifyblind_ios_prod` env group'undan gelir.
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

    // Cert pinning pin'leri artık koda gömülü tek kaynak (CertificatePinningDelegate.pinnedPublicKeys);
    // CERT_PIN_* secret/xcconfig yolu kaldırıldı (pin gizli değil, değişiklik zaten rebuild gerektirir).

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
