import Foundation
import CoreNFC

/// Kullanıcıya gösterilebilir NFC okuma hataları — Android NFC akışındaki hata yollarının
/// iOS karşılığı. Düşük seviye `NFCPassportReaderError` buraya eşlenir (`PassportNFCReader.map`).
///
/// Not: CAN (PACE-CAN) bu aşamada DESTEKLENMİYOR (AndyQ public API yalnızca `mrzKey` alır).
/// Türk kimlik kartları MRZ-BAC/PACE ile okunur; CAN sadece bazı yabancı kartlarda gerekir
/// (Alman nPA, Hollanda — `project_nfc_pace_can`). MRZ reddedilirse `.authenticationFailed`.
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
    /// kaldırıldığı için runtime kontrol şart (memory: codemagic gotcha #7).
    static var readingAvailable: Bool { NFCTagReaderSession.readingAvailable }

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Bu cihaz NFC okumayı desteklemiyor."
        case .cancelled:
            return "NFC okuma iptal edildi."
        case .invalidInput(let m):
            return "Geçersiz giriş: \(m). Lütfen MRZ alanlarını kontrol edin."
        case .authenticationFailed:
            return "Çip okunamadı. Belge No / Doğum Tarihi / Son Geçerlilik bilgilerini kontrol edin."
        case .connectionLost:
            return "Karta bağlantı koptu. Kartı cihazın üst arkasına sabit tutun."
        case .timeout:
            return "NFC okuma zaman aşımına uğradı. Tekrar deneyin."
        case .missingData(let m):
            return "Kart verisi eksik: \(m)."
        case .unknown(let m):
            return "Beklenmeyen NFC hatası: \(m)"
        }
    }
}
