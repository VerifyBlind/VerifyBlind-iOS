import Foundation

/// Çipten okunan ham veriler — Android `PassportReader.PassportData` (`PassportReader.kt:38-46`) eşdeğeri.
///
/// Tüm baytlar HAM çip baytlarıdır (re-encode YOK): SOD/DG1/DG15 tam dosya (header dahil,
/// Android `sod.encoded` / `dg1Raw` karşılığı), `faceImage` DG2'deki ham JPEG/JP2 (Android
/// `DG2_Photo`). Passive Authentication bu baytlar üzerinden ENCLAVE'de yapılır (istemcide değil).
struct ScannedPassport {
    let sod: Data
    let dg1: Data
    /// RAW DG2 EF baytları — SOD hash doğrulaması için gerekli (`faceImage` re-encode edildiğinden
    /// SOD hash'iyle eşleşmez). Android `PassportData.dg2Raw` karşılığı. (Güvenlik incelemesi Y-3.)
    let dg2Raw: Data?
    let dg15: Data?
    let faceImage: Data?
    let activeAuthSignature: Data
    let aaChallenge: Data
    let activeAuthPassed: Bool
    let activeAuthSupported: Bool

    // Parse edilmiş kolaylık alanları — sonraki aşamalarda countryIsoCode/cardId türetimi için.
    let documentNumber: String
    let nationality: String
    let issuingState: String
    let documentType: String

    /// Android `MainViewModel.finalizeRegistration` (`:479-491`) eşlemesi: NFC alanlarını
    /// `SecurePayload`'a (APIModels.swift) yerleştirir. Biyometri (DG2_Photo dışı) ve selfie
    /// alanları boş bırakılır — Aşama 3/4'te doldurulacak. Şifreleme + ağ gönderimi Aşama 4.
    func makeSecurePayload(userPubKey: String, nonce: String, timestamp: Int64, nonceSignature: String) -> SecurePayload {
        SecurePayload(
            sod: sod.base64EncodedString(),
            dg1: dg1.base64EncodedString(),
            dg2: dg2Raw?.base64EncodedString() ?? "",
            dg15: dg15?.base64EncodedString() ?? "",
            activeSig: activeAuthSignature.base64EncodedString(),
            aaChallenge: aaChallenge.base64EncodedString(),
            userPubKey: userPubKey,
            nonce: nonce,
            timestamp: timestamp,
            nonceSignature: nonceSignature,
            dg2Photo: faceImage?.base64EncodedString() ?? ""
        )
    }
}
