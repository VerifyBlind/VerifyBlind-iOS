import XCTest
import LocalAuthentication
@testable import VerifyBlind

/// LocalAuthentication hata kodu sınıflandırması — Sentry seviyesinin ve kullanıcı metninin tek kaynağı.
///
/// Regresyon zemini: kullanıcı kart eklemenin son adımında telefonu masaya bıraktı, prompt dokunulmadan
/// kaldı ve sistem onu iptal etti. Android'de bu, gerçek hata gibi işlenip Sentry'ye ERROR event yolladı
/// (VERIFYBLIND-ANDROID-W, 2026-08-21); iOS'ta kod atılıp `localizedDescription` saklandığı için aynı
/// durum warning event üretiyor ve cihaz diline göre ayrı issue'lara bölünüyordu. Bu testler eşlemeyi
/// ve "hata metni yalnız koddan üretilir" sözleşmesini sabitler.
final class BiometricErrorClassTests: XCTestCase {

    func testCancelCodesAreClassifiedAsCancelled() {
        // -4 (systemCancel) asıl vaka: ekran kilitlendi / uygulama arka plana düştü.
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.systemCancel.rawValue), .cancelled)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.userCancel.rawValue), .cancelled)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.appCancel.rawValue), .cancelled)
    }

    func testUserFixableCodesAreRecoverable() {
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.authenticationFailed.rawValue), .recoverable)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.biometryLockout.rawValue), .recoverable)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.biometryNotEnrolled.rawValue), .recoverable)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.passcodeNotSet.rawValue), .recoverable)
    }

    func testUnknownCodeIsFailure() {
        XCTAssertEqual(BiometricErrorClass.classify(code: BiometricErrorClass.unknownCode), .failure)
        XCTAssertEqual(BiometricErrorClass.classify(code: LAError.Code.invalidContext.rawValue), .failure)
    }

    func testLaCodeIsReadFromNSErrorDomain() {
        let ns = NSError(domain: LAErrorDomain, code: LAError.Code.systemCancel.rawValue, userInfo: nil)
        XCTAssertEqual(BiometricErrorClass.laCode(of: ns), LAError.Code.systemCancel.rawValue)
        // Alakasız domain → sentinel; sınıf `.failure` kalır (sessizce iptal SAYILMAZ).
        XCTAssertEqual(BiometricErrorClass.laCode(of: NSError(domain: "com.other", code: -4, userInfo: nil)),
                       BiometricErrorClass.unknownCode)
        XCTAssertEqual(BiometricErrorClass.laCode(of: nil), BiometricErrorClass.unknownCode)
    }

    func testFromAuthErrorMapsCancelAndFailureToDifferentCases() {
        let cancel = KeychainKeyStoreError.fromAuthError(
            NSError(domain: LAErrorDomain, code: LAError.Code.systemCancel.rawValue, userInfo: nil))
        guard case .authCancelled(let cancelCode) = cancel else {
            return XCTFail("systemCancel authCancelled olmalıydı, gelen: \(cancel)")
        }
        XCTAssertEqual(cancelCode, LAError.Code.systemCancel.rawValue)

        let lockout = KeychainKeyStoreError.fromAuthError(
            NSError(domain: LAErrorDomain, code: LAError.Code.biometryLockout.rawValue, userInfo: nil))
        guard case .authFailed(let failCode) = lockout else {
            return XCTFail("biometryLockout authFailed olmalıydı, gelen: \(lockout)")
        }
        XCTAssertEqual(failCode, LAError.Code.biometryLockout.rawValue)
    }

    /// Sentry gruplaması: açıklama yalnız sayısal kod taşımalı, cihaz diline göre değişen metin TAŞIMAMALI.
    func testDescriptionCarriesOnlyNumericCode() {
        XCTAssertEqual(KeychainKeyStoreError.authCancelled(code: -4).description, "authCancelled(LAError -4)")
        XCTAssertEqual(KeychainKeyStoreError.authFailed(code: -8).description, "authFailed(LAError -8)")
    }

    func testIsCancellationRecognisesBothErrorShapes() {
        XCTAssertTrue(BiometricErrorClass.isCancellation(KeychainKeyStoreError.authCancelled(code: -2)))
        XCTAssertTrue(BiometricErrorClass.isCancellation(
            NSError(domain: LAErrorDomain, code: LAError.Code.userCancel.rawValue, userInfo: nil)))
        XCTAssertFalse(BiometricErrorClass.isCancellation(KeychainKeyStoreError.authFailed(code: -8)))
        XCTAssertFalse(BiometricErrorClass.isCancellation(KeychainKeyStoreError.keyNotFound))
    }

    /// Kullanıcıya giden metin koddan seçilir; lockout'un kendi metni vardır.
    func testUserMessageKeySelection() {
        XCTAssertEqual(BiometricErrorClass.userMessageKey(code: LAError.Code.biometryLockout.rawValue),
                       "biometric_error_lockout_message")
        XCTAssertEqual(BiometricErrorClass.userMessageKey(code: LAError.Code.authenticationFailed.rawValue),
                       "biometric_error_retry_message")
    }

    /// Akışların `fail(...)` çağrıları bu metni okur — anahtar çözülmezse ekranda ham anahtar görünürdü.
    func testLocalizedMessagesResolve() {
        for key in ["biometric_cancelled_title", "biometric_cancelled_message",
                    "biometric_error_retry_message", "biometric_error_lockout_message"] {
            XCTAssertNotEqual(L.t(key), key, "Localizable.strings'te eksik anahtar: \(key)")
        }
        XCTAssertEqual(KeychainKeyStoreError.authCancelled(code: -4).errorDescription,
                       L.t("biometric_cancelled_message"))
        XCTAssertEqual(KeychainKeyStoreError.authFailed(code: LAError.Code.biometryLockout.rawValue).errorDescription,
                       L.t("biometric_error_lockout_message"))
        XCTAssertNil(KeychainKeyStoreError.keyNotFound.errorDescription)
    }
}
