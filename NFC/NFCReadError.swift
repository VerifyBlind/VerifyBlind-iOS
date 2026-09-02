import Foundation
import CoreNFC

/// Kullanıcıya gösterilebilir NFC okuma hataları — Android NFC akışındaki hata yollarının
/// iOS karşılığı. Düşük seviye `NFCPassportReaderError` buraya eşlenir (`PassportNFCReader.map`).
///
/// Not: CAN (PACE-CAN) bu aşamada DESTEKLENMİYOR (AndyQ public API yalnızca `mrzKey` alır).
/// Türk kimlik kartları MRZ-BAC/PACE ile okunur; CAN sadece bazı yabancı kartlarda gerekir
/// (Alman nPA, Hollanda). MRZ reddedilirse `.authenticationFailed`.
enum NFCReadError: Error, LocalizedError {
    case notAvailable
    case cancelled
    case invalidInput(String)
    /// BAC/PACE başarısız: MRZ bilgileri hatalı veya kart CAN gerektiriyor.
    case authenticationFailed
    case connectionLost
    case timeout
    case missingData(String)
    case unknown(String)

    /// Cihazda NFC etiket okuma destekleniyor mu? Info.plist'ten `UIRequiredDeviceCapabilities`
    /// kaldırıldığı için runtime kontrol şart.
    static var readingAvailable: Bool { NFCTagReaderSession.readingAvailable }

    /// Kullanıcıya gösterilen metinler — `L.t` üzerinden, sabit Türkçe DEĞİL. (Bunlar İngilizce
    /// arayüzde de Türkçe çıkıyordu; `.notAvailable` ve `.invalidInput` doğrudan hata ekranına
    /// basılıyor, bkz. `RegisterViewModel.runNfcAttempt`.) Anahtarlar yalnız iOS'ta tanımlıdır:
    /// Android NFC hatalarını tek bir ekran-içi `nfc_read_error` durumuyla gösteriyor, bu ayrıntılı
    /// ayrım CoreNFC'ye özgü.
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return L.t("nfc_err_not_available")
        case .cancelled:
            return L.t("nfc_err_cancelled")
        case .invalidInput(let m):
            return L.t("nfc_err_invalid_input", m)
        case .authenticationFailed:
            return L.t("nfc_err_auth_failed")
        case .connectionLost:
            return L.t("nfc_err_connection_lost")
        case .timeout:
            return L.t("nfc_err_timeout")
        case .missingData(let m):
            return L.t("nfc_err_missing_data", m)
        case .unknown(let m):
            return L.t("nfc_err_unknown", m)
        }
    }
}
