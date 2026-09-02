import Foundation
import Security

/// Çip imzasının **okunabilir** olup olmadığını NFC adımında anlar — Android
/// `ChipSignatureCheck` ile birebir aynı kural.
///
/// ## Neden var
/// Çip bazı okumalarda bozuk/eksik bir Aktif Kimlik Doğrulama yanıtı döndürüyor (kart oynadı,
/// kuplaj zayıf kaldı). Kullanıcı bunu bilmeden ~90 saniyelik canlılık testini yapıyor ve en
/// sonda sunucudan "çip doğrulanamadı" yiyordu (2026-08-24 vakası: aynı kartın ardışık iki
/// okumasından biri sağlam, diğeri bozuk). Bozukluğu NFC adımında yakalarsak kullanıcı kartı
/// hemen yeniden okutur.
///
/// ## Neden DOĞRULAMA değil, YAPI kontrolü
/// İstemci **sunucudan daha katı olamaz**. Buradaki kontrol hash'i doğrulamaz, imzayı kabul/ret
/// etmez; yalnız çözülen bloğun ISO 9796-2 (ya da PKCS#1) şeklinde OLUP OLMADIĞINA bakar.
/// Tam doğrulamayı istemciye taşımak, enclave'in kabul ettiği bir varyantı istemcinin tanımaması
/// riskini doğururdu — bu haftanın hatası tam olarak buydu (enclave yalnız SHA-256/açık trailer
/// tanıyordu ve SHA-1/örtük kartları reddediyordu). Yapı kontrolünde böyle bir sapma mümkün değil:
/// enclave'in kabul ettiği HER varyant bu testten geçer.
///
/// Bozuk okumada gözlenen blok: `hdr=4A … tr=C1AD` — başlık makul, trailer hiçbir şemaya uymuyor.
enum ChipSignatureCheck {

    /// Blok yapısı bir imza bloğuna benziyor mu? (Hash DOĞRULANMAZ.)
    ///
    /// - ISO 9796-2: ilk baytın üst yarısı `0x4` (tam kurtarma) ya da `0x6` (kısmi kurtarma),
    ///   son bayt `0xBC` (örtük trailer) veya `0xCC` (açık trailer'ın son baytı).
    /// - PKCS#1 v1.5: blok `0x01` ile başlar (baştaki `0x00` ham RSA çıktısında görünmez).
    static func looksLikeSignatureBlock(_ block: [UInt8]) -> Bool {
        guard let first = block.first, let last = block.last, block.count >= 3 else { return false }
        let head = first & 0xF0
        let isIso = (head == 0x40 || head == 0x60) && (last == 0xBC || last == 0xCC)
        let isPkcs1 = first == 0x01
        return isIso || isPkcs1
    }

    /// DG15'teki açık anahtarla ham RSA uygulayıp blok yapısını kontrol eder.
    ///
    /// Karar veremediğimiz her durumda (anahtar ayrıştırılamadı, RSA çalışmadı…) `true` döner:
    /// **şüphede kullanıcıyı durdurmayız**, kararı sunucuya bırakırız.
    static func isReadable(dg15: Data?, signature: Data?) -> Bool {
        guard let dg15, let signature, !dg15.isEmpty, !signature.isEmpty else { return true }
        guard let spki = spki(fromDG15: dg15),
              let key = RSAKey.publicKey(fromSPKI: spki) else { return true }

        // Ham RSA (padding yok) = m^e mod n. Girdi tam anahtar uzunluğunda olmalı.
        let keySize = SecKeyGetBlockSize(key)
        guard keySize > 0, signature.count >= keySize else { return true }
        let sig = signature.suffix(keySize)

        var error: Unmanaged<CFError>?
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw),
              let block = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, sig as CFData, &error) as Data? else {
            Log.debug("ChipSignatureCheck: ham RSA yapılamadı, karar sunucuya bırakıldı", category: .nfc)
            return true
        }

        // Ham çıktı baştaki sıfırlarla anahtar uzunluğunda gelir; ISO 9796-2 bloğu ilk anlamlı bayttan başlar.
        let trimmed = Array(block.drop { $0 == 0x00 })
        let ok = looksLikeSignatureBlock(trimmed)
        if !ok {
            Log.warning("Çip imzası okunabilir değil (blok yapısı bozuk) — yeniden okutma gerekiyor",
                        category: .nfc)
        }
        return ok
    }

    /// DG15 = `0x6F | uzunluk | SubjectPublicKeyInfo`. Sarmalayıcı yoksa girdi zaten SPKI'dır.
    private static func spki(fromDG15 dg15: Data) -> Data? {
        let bytes = [UInt8](dg15)
        guard bytes.count > 4 else { return nil }
        guard bytes[0] == 0x6F else { return dg15 }

        var offset = 1
        let lengthByte = bytes[offset]
        var length = 0
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
            offset += 1
        } else {
            let count = Int(lengthByte & 0x7F)
            offset += 1
            guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard length > 0, offset + length <= bytes.count else { return nil }
        return Data(bytes[offset..<(offset + length)])
    }
}
