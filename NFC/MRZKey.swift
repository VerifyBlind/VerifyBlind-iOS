import Foundation

/// Android `nfc/PassportReader.kt` MRZ giriş temizleme + ICAO BAC/PACE anahtarı üretimi portu.
///
/// Kullanıcının elle girdiği belge no / doğum tarihi / son geçerlilik alanları temizlenir,
/// ardından ICAO Doc 9303 BAC anahtar dizesi (`mrzKey`) üretilir. NFCPassportReader bu dizeyi
/// hem BAC hem PACE-MRZ için kullanır. Saf fonksiyonlar → `Stage2SelfTest`'ten çağrılabilir.
///
/// Android'de JMRTD `BACKey(docNo, dob, doe)` check digit'leri içeride hesaplıyordu; iOS'ta
/// kütüphane mrzKey'i hazır bekliyor, bu yüzden ICAO check digit matematiğini biz uyguluyoruz.
enum MRZKey {

    /// Android `cleanDocNo` (`PassportReader.kt:165-168`): boşlukları sil, büyük harfe çevir.
    static func cleanDocNo(_ input: String) -> String {
        input.replacingOccurrences(of: " ", with: "").uppercased()
    }

    /// Android `correctDateInput` (`PassportReader.kt:170-201`): ayraç temizleme + OCR alfa→rakam
    /// eşleme + 8 haneli DDMMYYYY → YYMMDD dönüşümü. Çıktı normalde 6 haneli YYMMDD.
    static func correctDateInput(_ input: String) -> String {
        var s = input
        for sep in ["/", ".", "-", " "] {
            s = s.replacingOccurrences(of: sep, with: "")
        }

        // OCR alfa hatalarını rakama eşle (Android ile birebir).
        let ocrMap: [Character: Character] = [
            "O": "0", "o": "0", "Q": "0", "D": "0",
            "I": "1", "l": "1", "L": "1",
            "Z": "2", "z": "2",
            "S": "5", "s": "5",
            "B": "8", "b": "8",
            "G": "6",
        ]
        s = String(s.map { ocrMap[$0] ?? $0 })

        // Yalnızca rakam (güvenlik).
        s = String(s.filter { $0.isNumber })

        let chars = Array(s)
        if chars.count == 8 {
            // DDMMYYYY varsay → YYMMDD
            let day = String(chars[0..<2])
            let month = String(chars[2..<4])
            let yearShort = String(chars[6..<8])
            return "\(yearShort)\(month)\(day)"
        } else if chars.count > 6 {
            return String(chars[0..<6])
        }
        return s
    }

    /// ICAO Doc 9303 BAC/PACE-MRZ anahtarı (NFCPassportReader örnek app `getMRZKey` portu).
    /// docNo 9'a `<` ile padlenir, tarihler 6'ya; her birine check digit eklenir.
    static func mrzKey(documentNumber: String, dateOfBirth: String, dateOfExpiry: String) -> String {
        let pptNr = pad(documentNumber, fieldLength: 9)
        let dob = pad(dateOfBirth, fieldLength: 6)
        let exp = pad(dateOfExpiry, fieldLength: 6)
        return "\(pptNr)\(checkSum(pptNr))\(dob)\(checkSum(dob))\(exp)\(checkSum(exp))"
    }

    /// Sağı `<` ile doldur (veya kırp) — ICAO sabit alan uzunluğu.
    static func pad(_ value: String, fieldLength: Int) -> String {
        String((value + String(repeating: "<", count: fieldLength)).prefix(fieldLength))
    }

    /// ICAO check digit: karakter→değer (0-9=kendisi, A-Z=10-35, `<`/boşluk=0),
    /// çarpan döngüsü [7,3,1], toplamın mod 10'u. Bilinmeyen karakterde 0.
    static func checkSum(_ checkString: String) -> Int {
        let multipliers = [7, 3, 1]
        var sum = 0
        var m = 0
        for c in checkString.uppercased() {
            let value: Int
            switch c {
            case "0"..."9":
                value = Int(String(c)) ?? 0
            case "<", " ":
                value = 0
            case "A"..."Z":
                value = Int(c.asciiValue! - UInt8(ascii: "A")) + 10
            default:
                return 0
            }
            sum += value * multipliers[m]
            m = (m + 1) % 3
        }
        return sum % 10
    }
}
