import Foundation

/// NFC okumasından SONRA, liveness'e geçmeden ÖNCE belgenin VerifyBlind akışıyla uyumlu olup
/// olmadığını belirler. Android `nfc/DocumentSupport.kt` **saf-byte/saf-string** portu.
///
/// Amaç: hızlı-başarısızlık — desteklenmeyen belgeyi kullanıcıyı tüm liveness'ten geçirip en sonda
/// enclave'in kriptik hatasına çarptırmak yerine, hemen net bir mesajla durdurmak.
///
/// **Kabul kuralı: yalnızca Türkiye Cumhuriyeti kimlik kartı.**
///   1. İhraç eden ülke `TUR` olmalı.
///   2. ICAO belge kodu `I` ya da `ID` olmalı (TD1 kimlik kartı). Pasaport (`P`) kabul EDİLMEZ.
///   3. DG2 yüz görüntüsü JPEG olmalı. iOS/enclave JPEG2000 (JP2) çözemez.
///   4. Active Authentication (DG15 + Aktif İmza) bulunmalı. Enclave AA'yı sert zorunlu tutar
///      (anti-downgrade); AA'sız (yalnız Chip-Auth'lu) belgeler reddedilir.
///
/// Türk pasaportu bilinçli olarak kapalı: DG2'si JPEG2000 olabilir ve AA yerine yalnız Chip
/// Authentication kullanıyor olabilir — gerçek bir pasaportla test edilmeden açılmamalı.
///
/// Bu tip kullanıcıya erken mesaj göstermek içindir; **otorite enclave'dedir**
/// (`DocumentPolicy.cs`) — değiştirilmiş bir istemci buradaki kapıyı atlayabilir.
///
/// Saf mantık (NFCPassportReader tipi bağımlılığı yok) → `Stage2SelfTest`'te doğrulanır.
enum DocumentSupport {

    /// Kabul edilen tek ihraç ülkesi (ICAO 3-harf kodu).
    static let acceptedCountry = "TUR"

    /// Kabul edilen ICAO belge kodları. TD1 kimlik kartında MRZ satır 1 "I<TUR.." ise kod "I",
    /// "IDTUR.." ise "ID" olur — ikisi de aynı fiziksel belgedir (üretim yılına göre değişir).
    static let acceptedDocumentCodes: Set<String> = ["I", "ID"]

    enum Verdict: Equatable {
        /// TC kimlik kartı + JPEG DG2 + Active Auth → tam akış desteklenir.
        case supported
        /// İhraç eden ülke Türkiye değil.
        case unsupportedCountry
        /// Ülke Türkiye ama belge kimlik kartı değil (ör. pasaport).
        case unsupportedDocType
        /// DG2'den yüz görüntüsü çıkarılamadı (biyometri imkânsız).
        case noFaceImage
        /// DG2 var ama JPEG değil (ör. JPEG2000) → ne iOS ne enclave çözebilir.
        case unsupportedImage
        /// DG15/Aktif İmza yok → enclave AA zorunluluğu reddeder (ERR_ACTIVE_AUTH).
        case noActiveAuth
    }

    /// Belgeyi değerlendirir.
    ///
    /// Sıra önemlidir: **ülke → belge tipi → görüntü → AA.** Yabancı bir pasaportta kullanıcıya
    /// "çip fotoğrafı JPEG2000" demek yanıltıcı olurdu (formatı düzeltirse kabul edilecekmiş gibi
    /// okunur); doğru mesaj "yalnızca TC kimlik kartı"dır. Görüntü sorunu da AA'dan önce raporlanır
    /// — kullanıcının ilk gördüğü problem fotoğrafın görünmemesidir ve biyometri görüntü olmadan
    /// zaten yapılamaz.
    static func evaluate(
        issuingState: String?,
        documentCode: String?,
        faceImage: Data?,
        dg15: Data?,
        activeSig: Data?
    ) -> Verdict {
        guard normalize(issuingState) == acceptedCountry else { return .unsupportedCountry }
        guard acceptedDocumentCodes.contains(normalize(documentCode)) else { return .unsupportedDocType }
        guard let faceImage, !faceImage.isEmpty else { return .noFaceImage }
        if !isJpeg(faceImage) { return .unsupportedImage }
        if (dg15?.isEmpty ?? true) || (activeSig?.isEmpty ?? true) { return .noActiveAuth }
        return .supported
    }

    /// MRZ alanlarını karşılaştırmaya hazırlar: büyük harf, ICAO dolgu karakteri '<' ve boşluk
    /// atılır. Okuyucu bu alanları genelde kırpılmış döndürür; bu savunmacı normalizasyon farklı
    /// kırpma davranışlarında kararın değişmemesini garanti eder.
    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return value.replacingOccurrences(of: "<", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    /// JPEG SOI işareti (FF D8 FF). JPEG2000 JP2 (00 00 00 0C 6A 50 ..) ve ham J2K codestream
    /// (FF 4F FF 51) bu kontrolden geçemez → reddedilir.
    static func isJpeg(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(3))
        return b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
    }
}
