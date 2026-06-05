import Foundation
import OSLog
import Sentry

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
}

private enum SentryBridge {
    static func capture(level: SentryLevel, category: LogCategory, message: String, error: Error? = nil) {
        guard SentrySDK.isEnabled else { return }

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
            options.beforeSend = { event in
                Self.redactPII(in: event)
                return event
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
            var redacted = msg
            if redacted.contains(where: \.isNumber), redacted.range(of: "\\b\\d{11}\\b", options: .regularExpression) != nil {
                redacted = redacted.replacingOccurrences(of: "\\b\\d{11}\\b", with: "<TCKN-redacted>", options: .regularExpression)
            }
            event.message = SentryMessage(formatted: redacted)
        }
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
