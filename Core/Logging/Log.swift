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
        // Sentry'e EVENT olarak GİTMEZ (kota tüketmez) — yalnızca breadcrumb bırakır. Bir crash/error
        // olduğunda son adımların izi raporun "Breadcrumbs" bölümünde görünür. (Önceden her info bir
        // event üretip ücretsiz plan error kotasını tüketiyordu — NFC tarama başına ~10 event.)
        SentryBridge.breadcrumb(level: .info, category: category, message: message)
    }

    /// [error] verilirse hem Sentry gruplaması stacktrace üzerinden yapılır hem de "cihazın
    /// interneti yok" durumu tespit edilebilir (bkz. `SentryBridge.capture`). Ağ/IO kaynaklı her
    /// uyarıda hatayı GEÇ — aksi halde uyarı, kullanıcı uçak modundayken de kotaya yazılır.
    static func warning(_ message: String, error: Error? = nil, category: LogCategory = .app) {
        if let error {
            loggers[category]?.warning("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        } else {
            loggers[category]?.warning("\(message, privacy: .public)")
        }
        SentryBridge.capture(level: .warning, category: category, message: message, error: error)
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
    /// `Log.info` ile aynı Sentry etkisi (event yok); fark sadece OSLog'a yazmaması.
    static func breadcrumb(_ message: String, category: LogCategory = .app) {
        SentryBridge.breadcrumb(level: .info, category: category, message: message)
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
        case .warning: warning(message, error: error, category: category)       // stacktrace/grup + offline tespiti için
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
            switch keychain {
            case .authCancelled:       return .info             // kullanıcı/sistem promptu kapattı → EVENT YOK
            case .authFailed(let code): return sentryLevel(forBiometricCode: code)
            default:                   return .error            // anahtar üretim/erişim arızası = gerçek
            }
        case is BiometricGateError:    return .warning          // biyometrik onay reddi/iptal
        case let la as LAError:        return sentryLevel(forBiometricCode: la.code.rawValue)
        case is URLError:              return .warning          // geçici bağlanırlık
        case is CancellationError:     return .info
        default:                       return .error            // kripto, decode, RegistrationError, bilinmeyen → gerçek arıza
        }
    }

    /// Biyometrik (LocalAuthentication) hata kodunun Sentry seviyesi — sınıflandırma tek yerde:
    /// [BiometricErrorClass]. İptal event üretmez; kullanıcı düzeltebilir durumlar warning kalır.
    private static func sentryLevel(forBiometricCode code: Int) -> SentryLevel {
        switch BiometricErrorClass.classify(code: code) {
        case .cancelled:   return .info
        case .recoverable: return .warning
        case .failure:     return .error
        }
    }
}

private enum SentryBridge {
    /// Yalnızca breadcrumb bırakır — EVENT yok, kota tüketmez. `Log.info`/`Log.breadcrumb` bunu kullanır.
    static func breadcrumb(level: SentryLevel, category: LogCategory, message: String) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: category.rawValue)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Breadcrumb + EVENT (kota tüketir). `Log.warning`/`Log.error` bunu kullanır — yalnızca warning ve üstü.
    static func capture(level: SentryLevel, category: LogCategory, message: String, error: Error? = nil) {
        guard SentrySDK.isEnabled else { return }

        // Her event aynı zamanda bir breadcrumb bırakır → crash raporu son adımların izini taşır.
        breadcrumb(level: level, category: category, message: message)

        // Cihazın interneti yokken oluşan taşıma hatası → EVENT YOK. Kullanıcının uçak modu bizim
        // raporumuz değil; kota gerçek arızalara ayrılır. Teşhis izi yukarıdaki breadcrumb'da kalır.
        // Tek kapı burada: warning, error ve failure'ın tamamı buradan geçer.
        if NetworkStatus.isOfflineTransportFailure(error) { return }

        if let error {
            SentrySDK.capture(error: error) { scope in
                // Seviye açıkça yazılır: `capture(error:)` varsayılanı .error'dur, warning
                // sınıflandırması aksi halde kaybolur ve her ağ uyarısı error olarak faturalanır.
                scope.setLevel(level)
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

            // --- Gizlilik kilidi: Session Replay ---
            // Android (VerifyBlindApp.kt) ile parite. Ekran kaydı = TCKN / selfie / NFC
            // ekranlarının videosu; kimlik uygulamasında ASLA açılmamalı. SDK varsayılanı
            // bugün 0, ama varsayılana güvenmiyoruz: kilit açıkça burada dursun.
            options.sessionReplay.sessionSampleRate = 0.0
            options.sessionReplay.onErrorSampleRate = 0.0
            // Ekran görüntüsü de kapalı: view hierarchy'nin aksine bu GERÇEK piksel —
            // TCKN / selfie ekranı doğrudan event'e düşer. Android ile parite.
            options.attachScreenshot = false

            // --- Crash yakalama ---
            // Crash anında ağ isteği güvenli değil (process ölüyor); SDK raporu DİSKE yazar ve
            // bir SONRAKİ açılışta otomatik gönderir. Aşağıdakiler hard-crash kapsamasını açık tutar.
            options.enableCrashHandler = true                  // sinyaller (SIGSEGV/SIGABRT/SIGBUS…) + NSException
            // OOM / watchdog kill. OTOMATİK TEST ALTINDA KAPALI: test pilotu uygulamayı her
            // turda birkaç kez `kill` ile öldürüyor ve SDK'nın sezgisi ("önceki oturum temiz
            // kapanmadı, çökme de değildi") bunu OS watchdog'u sanıyor. Ölçüldü: tek günlük
            // pilot kullanımı 127 sahte WatchdogTermination üretti — hem gerçek bir arıza gibi
            // görünüyor hem de aylık 5.000'lik hata kotasını yiyor.
            //
            // Bayrak yalnızca cihaza bağlı bir bilgisayardan (go-ios `launch --env=`)
            // verilebiliyor; gerçek kullanıcıda hiçbir zaman set olmaz, yani üretimde izleme
            // olduğu gibi açık kalıyor.
            let uiTest = ProcessInfo.processInfo.environment["VB_UI_TEST"] == "1"
            options.enableWatchdogTerminationTracking = !uiTest
            options.attachViewHierarchy = true                 // crash anındaki ekran ağacı raporu zenginleştirir
            // accessibilityIdentifier view hierarchy ekine dahil edilir (SDK varsayılanı: YES).
            // Kodda bugün hiç kullanılmıyor; ileride PII taşıyan bir identifier eklenirse
            // sessizce sızmasın diye peşinen kapalı.
            options.reportAccessibilityIdentifier = false
            options.onCrashedLastRun = { event in
                Log.info("Önceki oturum CRASH ile kapanmıştı — rapor Sentry'e iletildi (id: \(event.eventId.sentryIdString))", category: .app)
            }

            // --- App Hang (donma) ---
            // Ana thread bloklanmasının tek sinyali; açık tutulur (varsayılan 2sn eşiği).
            // V2 (SDK 8.50+, 9.0'da default) tam bloklanma ile kısmi bloklanmayı ayırt eder.
            // Kısmi olanlar KAPALI: birkaç frame render edilebildiği için stack trace'leri
            // yanıltıcı olabiliyor (Sentry dokümanının kendi uyarısı) → gürültü.
            options.enableAppHangTracking = true
            options.enableAppHangTrackingV2 = true
            options.enableReportNonFullyBlockingAppHangs = false

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
