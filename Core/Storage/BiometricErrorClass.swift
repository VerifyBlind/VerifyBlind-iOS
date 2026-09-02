import Foundation
import LocalAuthentication

/// LocalAuthentication hata kodu sınıfı — Android `BiometricHelper.ErrorClass` eşi.
///
/// Neden kod bazlı: `evaluatePolicy` başarısız olduğunda tek elde ettiğimiz `localizedDescription`
/// idi; hem cihaz diline göre değiştiği için Sentry gruplamasını bölüyor hem de "kullanıcı vazgeçti"
/// ile "donanım arızası"nı ayırt etmeyi imkânsız kılıyordu. Sonuç: kullanıcı Face ID ekranını
/// kapattığında ya da ekran kilitlendiğinde Sentry'ye event gidiyordu. Android'de aynı sorun
/// VERIFYBLIND-ANDROID-W issue'suyla görüldü (2026-08-21) ve orada da kod bazlı sınıflandırmaya geçildi.
enum BiometricErrorClass {
    /// Kullanıcı ya da sistem prompt'u kapattı → arıza DEĞİL, Sentry'ye EVENT YOK (yalnız breadcrumb).
    case cancelled
    /// Kullanıcı düzeltebilir (yanlış deneme, lockout, passcode/biyometri tanımsız) → Sentry WARNING.
    case recoverable
    /// Beklenmeyen / sınıflandırılamayan durum → Sentry ERROR.
    case failure

    /// LAError kodu okunamayan hatalar için sentinel (0 hiçbir LAError koduna karşılık gelmez).
    static let unknownCode = 0

    static func classify(code: Int) -> BiometricErrorClass {
        switch code {
        case LAError.Code.userCancel.rawValue,             // -2  kullanıcı "İptal"e bastı
             LAError.Code.systemCancel.rawValue,           // -4  sistem iptal etti (ekran kilitlendi, app arka plana düştü)
             LAError.Code.appCancel.rawValue:              // -9  uygulama iptal etti
            return .cancelled

        case LAError.Code.authenticationFailed.rawValue,   // -1  eşleşme başarısız
             LAError.Code.userFallback.rawValue,           // -3  kullanıcı şifreye geçmek istedi
             LAError.Code.passcodeNotSet.rawValue,         // -5  cihazda passcode yok
             LAError.Code.biometryNotAvailable.rawValue,   // -6  donanım kullanılamıyor
             LAError.Code.biometryNotEnrolled.rawValue,    // -7  kayıtlı yüz/parmak yok
             LAError.Code.biometryLockout.rawValue:        // -8  çok deneme → kilit
            return .recoverable

        default:
            return .failure
        }
    }

    /// Hatanın LAError kodu; LAError değilse [unknownCode].
    static func laCode(of error: Error?) -> Int {
        guard let error else { return unknownCode }
        if let la = error as? LAError { return la.code.rawValue }
        let ns = error as NSError
        return ns.domain == LAErrorDomain ? ns.code : unknownCode
    }

    /// Kullanıcıya gösterilecek yerelleştirilmiş metnin anahtarı.
    /// Sistemin `localizedDescription`'ı ASLA ekrana basılmaz (teknik metin, iOS sürümüne göre değişir).
    static func userMessageKey(code: Int) -> String {
        code == LAError.Code.biometryLockout.rawValue
            ? "biometric_error_lockout_message"
            : "biometric_error_retry_message"
    }

    /// Akış "hata ekranı" yerine nötr iptal metni göstermeli mi — kullanıcı/sistem promptu kapattıysa evet.
    static func isCancellation(_ error: Error) -> Bool {
        if let keychain = error as? KeychainKeyStoreError, case .authCancelled = keychain { return true }
        return classify(code: laCode(of: error)) == .cancelled
    }
}
