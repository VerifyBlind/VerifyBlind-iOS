import Foundation
import OSLog
import Sentry
import LocalAuthentication

/// Uygulama genelinde kategorili loglama.
///
/// İki hedef: (1) OSLog → Console.app (Mac varsa), (2) Sentry → cloud dashboard (Mac yoksa primary).
/// PII alanları (TCKN, MRZ ham, biyometrik) `.private` interpolation ile redakte edilir.
enum LogCategory: String, CaseIterable {
    case app
    case nfc
    case crypto
    case network
    case liveness
    case integrity
    case flow
    case backup
}

enum Log {
    private static let subsystem = "com.verifyblind.app"

    private static let loggers: [LogCategory: Logger] = {
        var dict: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            dict[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return dict
    }()

    static func debug(_ message: String, category: LogCategory = .app) {
        loggers[category]?.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String, category: LogCategory = .app) {
        loggers[category]?.info("\(message, privacy: .public)")
        SentryBridge.capture(level: .info, category: category, message: message)
    }

    static func warning(_ message: String, category: LogCategory = .app) {
        loggers[category]?.warning("\(message, privacy: .public)")
        SentryBridge.capture(level: .warning, category: category, message: message)
    }

    static func error(_ message: String, error: Error? = nil, category: LogCategory = .app) {
        if let error {
            loggers[category]?.error("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            SentryBridge.capture(level: .error, category: category, message: message, error: error)
        } else {
            loggers[category]?.error("\(message, privacy: .public)")
            SentryBridge.capture(level: .error, category: category, message: message)
        }
    }

    /// PII içeren alanlar için. OSLog'da `.private` privacy ile redakte edilir, Sentry'e GİTMEZ.
    static func sensitive(_ message: String, value: String, category: LogCategory = .app) {
        loggers[category]?.debug("\(message, privacy: .public): \(value, privacy: .private)")
    }

    /// Crash izi (breadcrumb). Event değil → kotaya yazılmaz; bir crash olduğunda son adımların
    /// listesi raporun "Breadcrumbs" bölümüne eklenir. Akış adımlarında çağır (NFC başladı, login gönderildi…).
    static func breadcrumb(_ message: String, category: LogCategory = .app) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: category.rawValue)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Bilinçli (deterministik) ölümcül hata. Önce Sentry'e mesajı SENKRON gönderip flush eder, SONRA
    /// çöker — böylece Swift `fatalError`'ın stderr'e giden açıklayıcı metni rapora dahil olur (normalde
    /// hard-crash sinyalinde sadece stack trace gider, metin GİTMEZ). Deterministik `fatalError` yollarında
    /// bunu kullan (örn. zorunlu config eksik). Hard crash'leri (nil-unwrap, sinyaller) SDK zaten otomatik yakalar.
    static func fatal(_ message: String, category: LogCategory = .app,
                      file: StaticString = #fileID, line: UInt = #line) -> Never {
        loggers[category]?.fault("\(message, privacy: .public)")
        if SentrySDK.isEnabled {
            let event = Event(level: .fatal)
            event.message = SentryMessage(formatted: message)
            event.tags = ["category": category.rawValue, "deterministic_fatal": "true"]
            SentrySDK.capture(event: event)
            SentrySDK.flush(timeout: 3.0)   // çökmeden önce ağ teslimini bekle
        }
        fatalError(message, file: file, line: line)
    }

    /// Kullanıcıya hata ekranı gösteren akış yolları (`fail`) için. Hatanın TÜRÜNE göre uygun Sentry
    /// seviyesinde raporlar: beklenen / geçici / kullanıcı kaynaklı hatalar (NFC okuma, ağ kopması,
    /// rate-limit, biyometrik iptal, 4xx) Sentry'de ERROR olarak GÖRÜNMEZ → warning/info'ya iner.
    /// Sadece gerçek kod/sistem arızaları (kripto, decode, anahtar üretimi, bilinmeyen) error gider.
    /// `Log.error` yerine bir akış başarısızlığını raporluyorsan bunu kullan.
    static func failure(_ message: String, error: Error? = nil, category: LogCategory = .app) {
        switch sentryLevel(for: error) {
        case .info:    info(message, category: category)
        case .warning: warning(message, category: category)
        default:       self.error(message, error: error, category: category)   // stacktrace/grup için error nesnesi iletilir
        }
    }

    /// `failure` seviye politikası. Sınıflandırılamayan hata = gerçek arıza varsayımı → `.error`
    /// (güvenli taraf: yeni/bilinmeyen bir hata sessizce yutulmaz, görünür kalır).
    private static func sentryLevel(for error: Error?) -> SentryLevel {
        // Hatasız (saf doğrulama / kullanıcı-durumu mesajı: geçersiz QR, kart yok…) → error değil.
        guard let error else { return .warning }

        switch error {
        case let nfc as NFCReadError:
            if case .cancelled = nfc { return .info }
            return .warning                                    // okuma hataları beklenen/çevresel — bkz kullanıcı geri bildirimi
        case let api as APIClientError:
            switch api {
            case .network:             return .warning         // geçici bağlanırlık (zaten retry'lı)
            case .rateLimited:         return .info            // beklenen kısıtlama
            case .http(let status, _): return (500...599).contains(status) ? .error : .warning  // 5xx=backend arızası, 4xx=istemci/kullanıcı
            case .decoding:            return .error           // sözleşme/uygulama hatası
            }
        case let keychain as KeychainKeyStoreError:
            if case .authFailed = keychain { return .warning } // biyometrik iptal/başarısız = kullanıcı (LAError string'e gömülü)
            return .error                                       // anahtar üretim/erişim arızası = gerçek
        case is BiometricGateError:    return .warning          // biyometrik onay reddi/iptal
        case is LAError:               return .warning          // local-auth durumu, kod hatası değil
        case is URLError:              return .warning          // geçici bağlanırlık
        case is CancellationError:     return .info
        default:                       return .error            // kripto, decode, RegistrationError, bilinmeyen → gerçek arıza
        }
    }
}

private enum SentryBridge {
    static func capture(level: SentryLevel, category: LogCategory, message: String, error: Error? = nil) {
        guard SentrySDK.isEnabled else { return }

        // Her log aynı zamanda bir breadcrumb bırakır → crash raporu son adımların izini taşır.
        let crumb = Breadcrumb(level: level, category: category.rawValue)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)

        if let error {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: category.rawValue, key: "category")
                scope.setExtra(value: message, key: "message")
            }
        } else {
            let event = Event(level: level)
            event.message = SentryMessage(formatted: message)
            event.tags = ["category": category.rawValue]
            SentrySDK.capture(event: event)
        }
    }
}

enum LogBootstrap {
    /// `VerifyBlindApp.init` içinde bir kez çağrılır.
    static func start() {
        let dsn = Config.sentryDSN
        guard !dsn.isEmpty else {
            Log.warning("SENTRY_DSN boş — cloud logging devre dışı.", category: .app)
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = Config.appAttestEnvironment.rawValue
            options.releaseName = "VerifyBlind@\(Bundle.main.shortVersion)+\(Bundle.main.buildNumber)"
            options.debug = Config.isDebugBuild
            options.enableAutoPerformanceTracing = false
            options.attachStacktrace = true

            // --- Crash yakalama ---
            // Crash anında ağ isteği güvenli değil (process ölüyor); SDK raporu DİSKE yazar ve
            // bir SONRAKİ açılışta otomatik gönderir. Aşağıdakiler hard-crash kapsamasını açık tutar.
            options.enableCrashHandler = true                  // sinyaller (SIGSEGV/SIGABRT/SIGBUS…) + NSException
            options.enableWatchdogTerminationTracking = true   // OOM / watchdog kill
            options.attachViewHierarchy = true                 // crash anındaki ekran ağacı raporu zenginleştirir
            options.onCrashedLastRun = { event in
                Log.info("Önceki oturum CRASH ile kapanmıştı — rapor Sentry'e iletildi (id: \(event.eventId.sentryIdString))", category: .app)
            }

            options.beforeSend = { event in
                Self.redactPII(in: event)
                return event
            }
            // Breadcrumb mesajları da PII filtresinden geçsin (TCKN sızıntısına karşı emniyet).
            options.beforeBreadcrumb = { crumb in
                if let msg = crumb.message {
                    crumb.message = Self.redactTCKN(in: msg)
                }
                return crumb
            }
        }
        Log.info("Sentry başlatıldı (env: \(Config.appAttestEnvironment.rawValue))", category: .app)
    }

    /// PII filtre — TCKN, MRZ ham, biyometrik veriler Sentry'e gitmez.
    private static func redactPII(in event: Event) {
        let piiKeys = ["tckn", "mrz", "biometric", "selfie", "dg1", "dg2", "user_pub_key", "encrypted_key", "aes_blob", "integrity_token"]

        if var extras = event.extra {
            for key in extras.keys where piiKeys.contains(where: { key.lowercased().contains($0) }) {
                extras[key] = "<redacted>"
            }
            event.extra = extras
        }

        if let msg = event.message?.formatted {
            event.message = SentryMessage(formatted: redactTCKN(in: msg))
        }
    }

    /// 11 haneli TCKN benzeri sayı dizilerini maskeler. Hem event mesajı hem breadcrumb için kullanılır.
    private static func redactTCKN(in text: String) -> String {
        guard text.contains(where: \.isNumber),
              text.range(of: "\\b\\d{11}\\b", options: .regularExpression) != nil else { return text }
        return text.replacingOccurrences(of: "\\b\\d{11}\\b", with: "<TCKN-redacted>", options: .regularExpression)
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
