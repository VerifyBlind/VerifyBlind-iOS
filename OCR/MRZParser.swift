import Foundation

/// MRZ ayrıştırma — Android `util/MrzAnalyzer.kt` (parse mantığı) **saf** portu.
///
/// Kamera/Vision'dan bağımsız: girdi olarak tanınan metin satırlarını alır, ICAO 9303 TD1
/// (TC kimlik, 3×30) ve TD3 (pasaport, 2×44) MRZ'sini ayrıştırır. Check digit (ağırlık 7-3-1)
/// ile OCR belirsizliklerini (S↔5, O/Q/U/D→0, Z↔2, B↔8) otomatik düzeltir. Saf olduğu için
/// `Stage3SelfTest`'te deterministik vektörlerle doğrulanır; çıktısı `MRZKey.mrzKey` (NFC) ile
/// birleşip çip okumayı sürer. Kamera akışı `OCR/MRZScanner.swift`'te.
enum MRZParser {

    /// Ayrıştırılmış MRZ alanları. `documentType`: "ID" (TD1) veya "PASSPORT" (TD3).
    struct Result: Equatable {
        let documentNumber: String
        let dateOfBirth: String   // YYMMDD
        let dateOfExpiry: String  // YYMMDD
        let documentType: String
    }

    /// Tanınan metni (çok satırlı) ayrıştırır. Eksik/geçersizse `nil`.
    /// Android `MrzAnalyzer.processText` ile birebir mantık.
    static func parse(_ text: String) -> Result? {
        let lines = text.split(separator: "\n").map(String.init).filter { $0.count > 20 }

        var docNo: String?
        var dob: String?
        var expiry: String?
        var documentType = "ID" // Varsayılan: TD1 kimlik kartı

        // ── Önce TD3 (pasaport) tespiti: Satır 1 = P<[Ülke3]... ──
        for line in lines {
            let clean = line.replacingOccurrences(of: " ", with: "").uppercased()
            if firstMatch("^P[<A-Z]([A-Z]{3})", clean) != nil, clean.count >= 40 {
                documentType = "PASSPORT"
            }
        }

        // ── Tespit edilen tipe göre alanları ayrıştır ──
        for line in lines {
            let clean = line.replacingOccurrences(of: " ", with: "").uppercased()

            if documentType == "PASSPORT" {
                // TD3 Satır 2: [DocNo9][C][Nat3][DOB6][C][Sex1][Exp6][C]...
                if clean.count >= 28, docNo == nil,
                   let g = firstMatch("^([A-Z0-9]{9})([0-9])([A-Z]{3})([0-9]{6})([0-9])([MF<])([0-9]{6})([0-9])", clean) {
                    let rawDocNo = g[1]
                    let docCheck = g[2].first ?? " "
                    let rawDob = g[4]
                    let dobCheck = g[5].first ?? " "
                    let rawExp = g[7]
                    let expCheck = g[8].first ?? " "

                    if isValidDate(rawDob), isValidDate(rawExp),
                       let fDoc = validateAndFix(rawDocNo, docCheck),
                       let fDob = validateAndFix(rawDob, dobCheck),
                       let fExp = validateAndFix(rawExp, expCheck) {
                        docNo = fDoc; dob = fDob; expiry = fExp
                    }
                }
            } else {
                // ── TD1 (kimlik): Satır 1 = [I/A/C]<[Ülke3][DocNo9][C][OptData] ──
                if firstMatch("^([IAC])<([A-Z]{3})", clean) != nil, clean.count >= 15 {
                    let chars = Array(clean)
                    let rawDocNo = String(chars[5..<14])
                    let rawCheck = chars[14]
                    if let fDoc = validateAndFix(rawDocNo, rawCheck) {
                        docNo = fDoc
                    }
                }

                // TD1 Satır 2: [DOB6][C][Sex1][Exp6][C]...
                if let g = firstMatch("([0-9]{6})([0-9])([MF<])([0-9]{6})([0-9])", clean) {
                    let rawDob = g[1]
                    let dobCheck = g[2].first ?? " "
                    let rawExp = g[4]
                    let expCheck = g[5].first ?? " "
                    if isValidDate(rawDob), isValidDate(rawExp),
                       let fDob = validateAndFix(rawDob, dobCheck),
                       let fExp = validateAndFix(rawExp, expCheck) {
                        dob = fDob; expiry = fExp
                    }
                }
            }
        }

        guard let d = docNo, let b = dob, let e = expiry else { return nil }
        return Result(documentNumber: d, dateOfBirth: b, dateOfExpiry: e, documentType: documentType)
    }

    // MARK: - ICAO check digit (ağırlık 7-3-1)

    static func checkDigit(_ input: String) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, c) in input.enumerated() {
            let value: Int
            switch c {
            case "0"..."9": value = Int(String(c)) ?? 0
            case "A"..."Z": value = Int(c.asciiValue! - Character("A").asciiValue! + 10)
            default: value = 0 // '<' ve diğerleri
            }
            sum += value * weights[i % 3]
        }
        return sum % 10
    }

    /// Checksum'a göre yaygın OCR hatalarını (S→5, O→0, vb.) doğrulayıp düzeltir.
    /// Android `MrzAnalyzer.validateAndFix` ile birebir.
    static func validateAndFix(_ value: String, _ checkChar: Character) -> String? {
        guard let target = Int(String(checkChar)) else { return nil }

        // 1. Orijinali dene
        if checkDigit(value) == target { return value }

        // 2. Belirsiz karakterleri düzelt
        let ambiguous = "S5O0QUDZ2B8"
        var indices: [Int] = []
        let chars = Array(value)
        for (i, c) in chars.enumerated() where ambiguous.contains(c) {
            indices.append(i)
        }
        if indices.count > 3 { return nil } // CPU yakma

        for idx in indices {
            for replacement in replacements(for: chars[idx]) {
                var candidate = chars
                candidate[idx] = replacement
                if checkDigit(String(candidate)) == target {
                    return String(candidate)
                }
            }
        }
        return nil
    }

    private static func replacements(for c: Character) -> [Character] {
        switch c {
        case "S", "s": return ["5"]
        case "5": return ["S"]
        case "O", "o", "Q", "U", "D": return ["0"]
        case "0": return ["O"]
        case "Z", "z": return ["2"]
        case "2": return ["Z"]
        case "B", "b": return ["8"]
        case "8": return ["B"]
        default: return []
        }
    }

    static func isValidDate(_ s: String) -> Bool {
        guard s.count == 6 else { return false }
        let chars = Array(s)
        guard let month = Int(String(chars[2...3])), let day = Int(String(chars[4...5])) else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    // MARK: - Regex yardımcısı

    /// İlk eşleşmeyi döndürür: index 0 = tam eşleşme, 1+ = capture grupları.
    private static func firstMatch(_ pattern: String, _ input: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let m = re.firstMatch(in: input, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: input) {
                groups.append(String(input[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}

/// 3-ardışık-aynı-okuma stabilite sayacı (Android `MrzAnalyzer` `stabilityCounter`).
/// Tarayıcı kullanır; tek bir kararlı sonuç verilince callback edilir. Saf parse'tan ayrı tutulur.
final class MRZStabilityTracker {
    private let requiredStableReads: Int
    private var last: MRZParser.Result?
    private var counter = 0

    init(requiredStableReads: Int = 3) {
        self.requiredStableReads = requiredStableReads
    }

    /// Yeni bir okuma ekler; stabilite eşiğine ulaşıldıysa sonucu döndürür (aksi halde nil).
    func accept(_ result: MRZParser.Result) -> MRZParser.Result? {
        if result == last {
            counter += 1
        } else {
            counter = 1
            last = result
        }
        if counter >= requiredStableReads {
            last = nil
            counter = 0
            return result
        }
        return nil
    }

    func reset() {
        last = nil
        counter = 0
    }
}
