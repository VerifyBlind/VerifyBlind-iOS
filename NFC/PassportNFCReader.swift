import Foundation
import NFCPassportReader

/// Android `nfc/PassportReader.readPassport` çekirdeğinin iOS portu.
///
/// AndyQ `NFCPassportReader`'ı sarar: MRZ anahtarı üretir, Active Authentication challenge'ını
/// handshake nonce'undan türetir (Enclave şartı: `SHA-256(nonce)[0..7]`, `EnclaveService.cs:824-837`),
/// çipi okur ve ham veriyi `ScannedPassport`'a eşler.
///
/// Passive Authentication İSTEMCİDE yapılmaz (`masterListURL: nil`) — CSCA/CRL doğrulaması
/// Enclave'de gerçekleşir (zero-knowledge: istemci güvenilmez). SOD + DG1/DG2/DG15 açıkça istenir
/// (COM her zaman okunur). DG11/DG13 gibi ekstra PII okunmaz.
///
/// ⚠️ `.SOD` `tags`'e AÇIKÇA eklenmeli: NFCPassportReader yalnızca BOŞ `tags`'te SOD'u otomatik
/// ekler; non-boş `tags`'te `readDataGroups` "readAllDatagroups != true" filtresiyle SOD'u okuma
/// listesinden çıkarır → `getDataGroup(.SOD)` nil döner ("Kart verisi eksik: SOD" hatası).
final class PassportNFCReader {

    func read(documentNumber: String, dateOfBirth: String, dateOfExpiry: String, handshakeNonce: String) async throws -> ScannedPassport {
        guard NFCReadError.readingAvailable else { throw NFCReadError.notAvailable }

        let docNo = MRZKey.cleanDocNo(documentNumber)
        let dob = MRZKey.correctDateInput(dateOfBirth)
        let doe = MRZKey.correctDateInput(dateOfExpiry)

        guard !docNo.isEmpty, dob.count == 6, doe.count == 6 else {
            throw NFCReadError.invalidInput("Belge No / Doğum Tarihi / Son Geçerlilik")
        }

        let mrzKey = MRZKey.mrzKey(documentNumber: docNo, dateOfBirth: dob, dateOfExpiry: doe)

        // AA challenge: SHA-256(nonce)[:8] — Android (`MainActivity.kt:592-597`) ile birebir.
        let challenge = Array(CryptoUtils.sha256Bytes(handshakeNonce).prefix(8))

        Log.info("NFC okuma başlıyor (mrzKey hazır, AA challenge \(challenge.count)B)", category: .nfc)
        Log.sensitive("NFC mrzKey", value: mrzKey, category: .nfc)

        let reader = PassportReader(masterListURL: nil)
        let model: NFCPassportModel
        do {
            // customDisplayMessage atlandı → kütüphane varsayılan metni. Türkçe ekran metinleri
            // gerçek Register akışında (Aşama 4) eklenecek.
            model = try await reader.readPassport(
                mrzKey: mrzKey,
                tags: [.SOD, .DG1, .DG2, .DG15],
                aaChallenge: challenge
            )
        } catch let e as NFCPassportReaderError {
            Log.warning("NFC okuma başarısız: \(e)", category: .nfc)
            throw Self.map(e)
        } catch {
            Log.error("NFC okuma beklenmeyen hata", error: error, category: .nfc)
            throw NFCReadError.unknown("\(error)")
        }

        guard let sodBytes = model.getDataGroup(.SOD)?.data, !sodBytes.isEmpty else {
            throw NFCReadError.missingData("SOD")
        }
        guard let dg1Bytes = model.getDataGroup(.DG1)?.data, !dg1Bytes.isEmpty else {
            throw NFCReadError.missingData("DG1")
        }
        let dg15Bytes = model.getDataGroup(.DG15)?.data
        let faceBytes = (model.getDataGroup(.DG2) as? DataGroup2)?.imageData

        let scanned = ScannedPassport(
            sod: Data(sodBytes),
            dg1: Data(dg1Bytes),
            dg15: (dg15Bytes?.isEmpty == false) ? Data(dg15Bytes!) : nil,
            faceImage: (faceBytes?.isEmpty == false) ? Data(faceBytes!) : nil,
            activeAuthSignature: Data(model.activeAuthenticationSignature),
            aaChallenge: Data(challenge),
            activeAuthPassed: model.activeAuthenticationPassed,
            activeAuthSupported: model.activeAuthenticationSupported,
            documentNumber: model.documentNumber,
            nationality: model.nationality,
            issuingState: model.issuingAuthority,
            documentType: model.documentType
        )

        Log.info(
            "NFC okuma tamam: DG1=\(scanned.dg1.count)B DG2=\(scanned.faceImage?.count ?? 0)B " +
            "DG15=\(scanned.dg15?.count ?? 0)B SOD=\(scanned.sod.count)B " +
            "AAsupported=\(scanned.activeAuthSupported) AApassed=\(scanned.activeAuthPassed) " +
            "AAsig=\(scanned.activeAuthSignature.count)B",
            category: .nfc
        )
        return scanned
    }

    // MARK: - Hata eşleme (NFCPassportReaderError → NFCReadError)

    private static func map(_ e: NFCPassportReaderError) -> NFCReadError {
        switch e {
        case .UserCanceled:
            return .cancelled
        case .NFCNotSupported:
            return .notAvailable
        case .ConnectionError, .NoConnectedTag, .TagNotValid:
            return .connectionLost
        case .TimeOutError:
            return .timeout
        case .InvalidMRZKey, .PACEError:
            return .authenticationFailed
        default:
            return .unknown("\(e)")
        }
    }
}
