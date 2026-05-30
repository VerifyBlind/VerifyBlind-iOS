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
            fatalError("Config: API_BASE_URL geçersiz veya eksik. xcconfig dosyasını kontrol edin.")
        }
        return url
    }()

    static let certPins: [String] = {
        [string("CERT_PIN_1"), string("CERT_PIN_2")].filter { !$0.isEmpty }
    }()

    /// Enclave PCR0 imzalarını doğrulamak için kullanılan RSA public key (base64 SPKI).
    static let enclaveDeveloperPublicKey: String = string("ENCLAVE_DEVELOPER_PUBLIC_KEY")

    static let appAttestEnvironment: AppAttestEnvironment = {
        let raw = string("APP_ATTEST_ENVIRONMENT")
        return AppAttestEnvironment(rawValue: raw) ?? .development
    }()

    static let iCloudContainerID: String = string("ICLOUD_CONTAINER_ID")

    static let sentryDSN: String = string("SENTRY_DSN")

    static let dropboxAppKey: String = string("DROPBOX_IOS_APP_KEY")

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func string(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value
    }
}
