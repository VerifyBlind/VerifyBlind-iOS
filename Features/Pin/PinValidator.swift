import Foundation

/// TCKN'siz kimliklerin bulut yedek PIN'i için doğrulama kuralı — Android `ui/pin/PinValidator.kt`
/// paritesi. Saf → uygulama-içi self-test ile kapsanır.
///
/// Kural: en az 6 hane, yalnız rakam. **Yaygın-PIN blocklist'i BİLİNÇLİ OLARAK YOK** (ürün kararı):
/// kullanıcı unutmayacağı PIN'i seçebilmeli. Kaba kuvvet freni istemcide değil SUNUCUDADIR
/// (PinDeriveRateLimiter: UUID başına 10/gün + cihaz attestation'ı).
enum PinValidator {

    static let minLength = 6

    static func isValid(_ pin: String) -> Bool {
        pin.count >= minLength && pin.allSatisfy { $0.isNumber && $0.isASCII }
    }
}
