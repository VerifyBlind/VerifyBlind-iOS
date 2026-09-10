import Foundation

/// Asgari yaş kapısı. Kullanım Şartları "on beş yaşını doldurmamış kullanıcılar" hizmet kapsamı
/// dışında der; bu kural 2026-09-11'e kadar KODDA HİÇ UYGULANMIYORDU — sözleşme bir şey diyor,
/// uygulama başka şey yapıyordu.
///
/// **Neden `DocumentSupport`'tan ayrı:** DocumentSupport belgenin *teknik olarak işlenebilir*
/// olup olmadığına bakar (ülke, tip, DG2 formatı, AA). Yaş ise bir *politika* kararıdır — belge
/// kusursuz okunur, akış yine de reddedilir.
///
/// **Neden fotoğraf kontrolünden ÖNCE çağrılır:** 15 yaşını doldurmamış birinin kartı zaten
/// fotoğrafsız düzenlenir (fotoğraf yalnızca veli talebi ya da seyahat belgesi beyanıyla eklenir).
/// Yaş bakılmadan önce fotoğrafa bakılırsa kullanıcı "çipte fotoğraf yok" mesajını alır ve
/// **nüfus müdürlüğünden fotoğraflı kart çıkartırsa çözüleceğini sanır** — çözülmez, engel yaştır.
///
/// Android `nfc/AgePolicy.kt` ile birebir paritelidir; biri değişince diğeri de değişmeli.
enum AgePolicy {

    /// Hizmetin açık olduğu en küçük yaş. Kullanım Şartları'ndaki ifadeyle hizalı tutulur.
    static let minimumAge = 15

    enum Verdict: Equatable {
        /// Yaş sınırı karşılanıyor (ya da doğum tarihi okunamadı → karar enclave'e bırakılır).
        case allowed
        /// Kullanıcı `minimumAge` yaşını doldurmamış → kayıt reddedilir.
        case underMinimumAge
    }

    /// MRZ'nin `YYMMDD` doğum tarihini bugünkü tarihe göre değerlendirir.
    ///
    /// - Parameters:
    ///   - mrzDateOfBirth: ICAO MRZ doğum tarihi alanı (6 hane, `YYMMDD`).
    ///   - today: Testlerde sabitlenebilsin diye dışarıdan verilir.
    static func evaluate(mrzDateOfBirth: String?, today: Date = Date()) -> Verdict {
        var calendar = Calendar(identifier: .gregorian)
        // MRZ tarihleri takvim günüdür; cihazın saat dilimi kararı kaydırmamalı.
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        guard let birthDate = parseMrzDate(mrzDateOfBirth, today: today, calendar: calendar) else {
            return .allowed
        }
        let age = calendar.dateComponents([.year], from: birthDate, to: today).year ?? Int.max
        return age < minimumAge ? .underMinimumAge : .allowed
    }

    /// MRZ `YYMMDD` → `Date`. Ayrıştırılamayan değerde **nil** döner ve çağıran akışı SÜRDÜRÜR:
    /// istemcideki bu kapı yalnızca erken/net mesaj içindir, bozuk bir MRZ okuması yüzünden meşru
    /// kullanıcıyı kilitlemek yanlış olur. Nihai otorite enclave'dedir.
    ///
    /// **Yüzyıl kuralı:** MRZ yılı 2 hanedir, yani "30" hem 1930 hem 2030 olabilir. Doğum tarihi
    /// geçmişte olmak zorunda olduğundan: 2000'li yüzyıl varsayılır, sonuç bugünden İLERİDEYSE
    /// 1900'e düşülür. Böylece 2026'da "27" → 1927 (2027 henüz gelmedi), "10" → 2010 olur.
    private static func parseMrzDate(_ value: String?, today: Date, calendar: Calendar) -> Date? {
        let digits = (value ?? "").replacingOccurrences(of: "<", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard digits.count == 6, digits.allSatisfy({ $0.isNumber }) else { return nil }

        let chars = Array(digits)
        guard let yy = Int(String(chars[0...1])),
              let mm = Int(String(chars[2...3])),
              let dd = Int(String(chars[4...5])) else { return nil }

        func makeDate(year: Int) -> Date? {
            var components = DateComponents()
            components.year = year
            components.month = mm
            components.day = dd
            // Geçersiz ay/gün (ör. "991332") sessizce kaydırılmasın: bileşenler doğrulanır.
            guard let date = calendar.date(from: components),
                  calendar.component(.month, from: date) == mm,
                  calendar.component(.day, from: date) == dd else { return nil }
            return date
        }

        guard let candidate = makeDate(year: 2000 + yy) else { return nil }
        if candidate > today { return makeDate(year: 1900 + yy) }
        return candidate
    }
}
