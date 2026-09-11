import XCTest
import LocalAuthentication
@testable import VerifyBlind

/// Biyometrik hata metinlerinin kullanıcıya ULAŞTIĞININ sözleşmesi.
///
/// Regresyon zemini (parite denetimi 2026-09-03, O-2): `KeychainKeyStoreError` yerelleştirilmiş
/// metnini (deneme kilidi / tekrar dene) zaten üretiyordu, ama akışların kullandığı
/// `UserFacingError.message(for:)` `LocalizedError`'a HİÇ bakmıyordu. Sonuç: Face ID kilitlenen
/// kullanıcı "beklenmeyen hata" görüyor, ne yapması gerektiği (şifreyle devam et / birkaç dakika
/// bekle) söylenmiyordu. Anahtar çevriliydi, yol bağlı değildi — `parity-scan --dead` bu sınıfı
/// göremez, çünkü anahtar kodda "canlı" görünür.
///
/// Aşağıdaki eşleme bozulursa metinler yeniden sessizce ölür.
final class BiometricErrorRoutingTests: XCTestCase {

    func testLockoutMessageReachesTheUser() {
        let error = KeychainKeyStoreError.authFailed(code: LAError.Code.biometryLockout.rawValue)

        XCTAssertEqual(UserFacingError.message(for: error), L.t("biometric_error_lockout_message"))
        XCTAssertNotEqual(UserFacingError.message(for: error), L.t("error_internal_generic"),
                          "Deneme kilidi 'beklenmeyen hata' olarak gösterilmemeli.")
        XCTAssertEqual(UserFacingError.title(for: error), L.t("biometric_error_title"))
    }

    func testOtherAuthFailuresGetTheRetryMessage() {
        let error = KeychainKeyStoreError.authFailed(code: LAError.Code.authenticationFailed.rawValue)

        XCTAssertEqual(UserFacingError.message(for: error), L.t("biometric_error_retry_message"))
        XCTAssertEqual(UserFacingError.title(for: error), L.t("biometric_error_title"))
    }

    /// İptal bir HATA değildir: nötr başlık + nötr metin (akışlar bunu ayrıca erken yakalar,
    /// ama bu yoldan geçerse de doğru metni göstermeli).
    func testCancellationKeepsItsNeutralCopy() {
        let error = KeychainKeyStoreError.authCancelled(code: LAError.Code.userCancel.rawValue)

        XCTAssertEqual(UserFacingError.message(for: error), L.t("biometric_cancelled_message"))
        XCTAssertEqual(UserFacingError.title(for: error), L.t("biometric_cancelled_title"))
    }

    /// Biyometrik OLMAYAN Keychain arızaları akışın kendi mesajına düşmeye devam etmeli —
    /// yeni dal genel yolu ele geçirmemiş olsun.
    func testNonBiometricKeychainErrorsStillFallBackToTheFlowCopy() {
        let error = KeychainKeyStoreError.keyNotFound

        XCTAssertEqual(UserFacingError.message(for: error, internalFallbackKey: "error_registration_server"),
                       L.t("error_registration_server"))
        XCTAssertEqual(UserFacingError.title(for: error, internalFallbackKey: "registration_failed_status"),
                       L.t("registration_failed_status"))
    }

    /// Ağ hataları hâlâ bağlantı metnini almalı: yeni Keychain dalı sıralamayı bozmamış olsun.
    func testTransportFailuresAreUnaffected() {
        XCTAssertEqual(UserFacingError.message(for: URLError(.notConnectedToInternet)),
                       L.t("error_connection_generic"))
        XCTAssertEqual(UserFacingError.title(for: URLError(.notConnectedToInternet)),
                       L.t("connection_error_title"))
    }
}
