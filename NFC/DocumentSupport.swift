import Foundation

/// NFC okumasından SONRA, liveness'e geçmeden ÖNCE belgenin VerifyBlind akışıyla uyumlu olup
/// olmadığını belirler. Android `nfc/DocumentSupport.kt` **saf-byte** portu.
///
/// Amaç: hızlı-başarısızlık — desteklenmeyen belgeyi (ör. Taylan pasaportu) kullanıcıyı tüm
/// liveness'ten geçirip en sonda enclave'in kriptik `ERR_ACTIVE_AUTH`'una çarptırmak yerine,
/// hemen net bir mesajla durdurmak.
///
/// İki sert kısıt (VerifyBlind şu an YALNIZCA Türk kimlik kartı sınıfını destekliyor):
///   1. DG2 yüz görüntüsü JPEG olmalı. iOS/enclave JPEG2000 (JP2) çözemez → birçok pasaport
///      (Taylan dahil) DG2'yi JP2 saklar. JP2 = decode edilemez.
///   2. Active Authentication (DG15 + Aktif İmza) bulunmalı. Enclave AA'yı sert zorunlu tutar
///      (anti-downgrade); AA'sız (yalnız Chip-Auth'lu) belgeler reddedilir.
///
/// Saf-byte mantığı (NFCPassportReader tipi bağımlılığı yok) → `Stage2SelfTest`'te doğrulanır.
enum DocumentSupport {

    enum Verdict: Equatable {
        /// JPEG DG2 + Active Auth mevcut → tam akış desteklenir.
        case supported
        /// DG2'den yüz görüntüsü çıkarılamadı (biyometri imkânsız).
        case noFaceImage
        /// DG2 var ama JPEG değil (ör. JPEG2000) → ne iOS ne enclave çözebilir.
        case unsupportedImage
        /// DG15/Aktif İmza yok → enclave AA zorunluluğu reddeder (ERR_ACTIVE_AUTH).
        case noActiveAuth
    }

    /// Belgeyi değerlendirir. Görüntü sorunu AA'dan önce raporlanır (kullanıcının ilk gördüğü
    /// problem fotoğrafın görünmemesidir; ayrıca biyometri görüntü olmadan zaten yapılamaz).
    static func evaluate(faceImage: Data?, dg15: Data?, activeSig: Data?) -> Verdict {
        guard let faceImage, !faceImage.isEmpty else { return .noFaceImage }
        if !isJpeg(faceImage) { return .unsupportedImage }
        if (dg15?.isEmpty ?? true) || (activeSig?.isEmpty ?? true) { return .noActiveAuth }
        return .supported
    }

    /// JPEG SOI işareti (FF D8 FF). JPEG2000 JP2 (00 00 00 0C 6A 50 ..) ve ham J2K codestream
    /// (FF 4F FF 51) bu kontrolden geçemez → reddedilir.
    static func isJpeg(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(3))
        return b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
    }
}
