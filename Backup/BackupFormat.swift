import Foundation

/// Android `backup/BackupFormat.kt`'nin portu — bulut yedek sürüm şeması ve DEK sarma/açma.
///
/// **v1 (eski):** geçmiş öğeleri DOĞRUDAN `SHA256(personId)` ile şifreli.
/// **v2 (yeni):** geçmiş öğeleri rastgele bir DEK ile şifreli; DEK, `KEK = SHA256(personId)` ile
/// sarılıp `wraps[]` dizisinde tutulur.
///
/// **Neden:** v1'de ciphertext bir kimlik koduna sabitlenmişti → person_id'nin türetimi değişince
/// (ör. TCKN'siz belgeler) eski yedek çözülemez hale gelirdi. v2'de aynı DEK BİRDEN ÇOK KEK ile
/// sarılabilir → kimlik tabanı değişince yalnız yeni bir wrap eklenir, geçmiş ASLA yeniden
/// şifrelenmez.
///
/// **Kimlik izolasyonu:** her kimliğin AYRI DEK'i vardır → A kişisi B'nin DEK'ini açamaz (v1'deki
/// izolasyon aynen sürer). Düz metinde kimlik etiketi (kid) YOKTUR — hangi öğenin hangi kimliğe ait
/// olduğu sızmaz. Çözüm mevcut desenle aynı: bilinen tüm personId'lerle tüm wrap'ler denenir.
///
/// **Yabancı wrap/öğe:** açılamayanlar AYNEN korunur → başka kimliğin yedeği yok edilmez.
enum BackupFormat {

    static let versionV2 = 2

    static func isV2(_ payload: CloudPayload?) -> Bool {
        payload?.v == versionV2
    }

    /// DEK'i personId'den türetilen KEK ile sarar. (Android `wrapDek`.)
    static func wrapDek(_ dek: Data, personId: String, pinUuid: String?) throws -> DekWrap {
        let kek = CryptoUtils.kekFromPersonId(personId)
        let dekB64 = dek.base64EncodedString()
        let (enc, iv) = try CryptoUtils.aesGcmEncryptRaw(dekB64, key: kek)
        return DekWrap(enc: enc, iv: iv, pinUuid: pinUuid)
    }

    /// Verilen personId'lerle açılabilen TÜM DEK'leri döner. (Android `unwrapDeks`.)
    ///
    /// Açılamayan wrap'ler (başka kimliğe ait) sessizce atlanır — çağıran taraf onları AYNEN
    /// korumalıdır, yoksa o kimliğin DEK'i kalıcı olarak kaybolur.
    static func unwrapDeks(_ wraps: [DekWrap], personIds: [String]) -> [Data] {
        var out: [Data] = []
        for w in wraps {
            for pid in personIds {
                let kek = CryptoUtils.kekFromPersonId(pid)
                guard let dekB64 = try? CryptoUtils.aesGcmDecryptRaw(
                    ciphertextBase64: w.enc, ivBase64: w.iv, key: kek),
                      let dek = Data(base64Encoded: dekB64),
                      dek.count == 32
                else {
                    // Yanlış KEK (GCM tag uyumsuz) ya da bozuk wrap → sıradaki personId'yi dene.
                    continue
                }
                out.append(dek)
                break
            }
        }
        return out
    }

    /// Bir şifreli bloğu formatın gerektirdiği anahtarlarla çözmeyi dener. (Android `tryDecrypt`.)
    ///   v2 → DEK'lerle (ham anahtar; DEK kimlikten bağımsız).
    ///   v1 → personId'lerle (anahtar personId'den türetilir).
    /// Hiçbiriyle çözülemezse nil → çağıran taraf "yabancı" sayıp AYNEN korumalıdır.
    static func tryDecrypt(
        enc: String,
        iv: String,
        isV2: Bool,
        deks: [Data],
        personIds: [String]
    ) -> String? {
        if isV2 {
            for dek in deks {
                if let s = try? CryptoUtils.aesGcmDecryptRaw(ciphertextBase64: enc, ivBase64: iv, key: dek) {
                    return s
                }
            }
        } else {
            for pid in personIds {
                if let s = try? CryptoUtils.aesGcmDecrypt(ciphertextBase64: enc, ivBase64: iv, personId: pid) {
                    return s
                }
            }
        }
        return nil
    }
}
