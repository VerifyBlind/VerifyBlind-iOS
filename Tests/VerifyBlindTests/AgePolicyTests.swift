import XCTest
@testable import VerifyBlind

/// `AgePolicy` birim testleri — Android `AgePolicyTest.kt` ile birebir paritelidir.
/// Kritik davranışlar:
///   - 15 yaşını doldurmamış → underMinimumAge
///   - Doğum günü sınırı (tam 15 / bir gün eksik)
///   - MRZ 2 haneli yıl yüzyıl çözümü (geleceğe düşen yıl 1900'e iner)
///   - Ayrıştırılamayan MRZ → allowed (fail-open; otorite enclave)
final class AgePolicyTests: XCTestCase {

    /// Testlerin bugünü — sabit tutulur ki takvim ilerledikçe testler kırılmasın.
    private var today: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 11
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    private func evaluate(_ dob: String?) -> AgePolicy.Verdict {
        AgePolicy.evaluate(mrzDateOfBirth: dob, today: today)
    }

    func testOnYasindakiCocukReddedilir() {
        // 2016-05-20 → 2026-09-11'de 10 yaşında
        XCTAssertEqual(evaluate("160520"), .underMinimumAge)
    }

    func testOnDortYasindakiCocukReddedilir() {
        // 2012-01-01 → 14 yaşında
        XCTAssertEqual(evaluate("120101"), .underMinimumAge)
    }

    func testDogumGunundenBirGunOnceHalaReddedilir() {
        // 2011-09-12 → 2026-09-11'de henüz 14 (doğum günü yarın)
        XCTAssertEqual(evaluate("110912"), .underMinimumAge)
    }

    func testOnBesinciDogumGunundeKabulEdilir() {
        // 2011-09-11 → bugün tam 15 oldu
        XCTAssertEqual(evaluate("110911"), .allowed)
    }

    func testOnAltiYasindakiKullaniciKabulEdilir() {
        // 2010-03-15 → 16 yaşında
        XCTAssertEqual(evaluate("100315"), .allowed)
    }

    func testYetiskinKabulEdilir() {
        // "90" → 2090 gelecekte olduğu için 1990 kabul edilir
        XCTAssertEqual(evaluate("900101"), .allowed)
    }

    func testYuzyilCozumuGelecegeDusenYili1900lereIndirir() {
        // "270101" → 2027-01-01 gelecekte → 1927-01-01 → yaşlı, allowed
        XCTAssertEqual(evaluate("270101"), .allowed)
    }

    func testBuYilDoganBebekReddedilir() {
        // 2026-01-05 → 0 yaşında
        XCTAssertEqual(evaluate("260105"), .underMinimumAge)
    }

    func testNilMrzKarariEnclaveeBirakir() {
        XCTAssertEqual(evaluate(nil), .allowed)
    }

    func testBosMrzKarariEnclaveeBirakir() {
        XCTAssertEqual(evaluate(""), .allowed)
    }

    func testEksikHaneliMrzKarariEnclaveeBirakir() {
        XCTAssertEqual(evaluate("1105"), .allowed)
    }

    func testRakamOlmayanMrzKarariEnclaveeBirakir() {
        XCTAssertEqual(evaluate("11AB11"), .allowed)
    }

    func testGecersizAyGunKarariEnclaveeBirakir() {
        // "991332" → 13. ay / 32. gün yok; sessizce kaydırılmamalı
        XCTAssertEqual(evaluate("991332"), .allowed)
    }

    func testMrzDolguKarakteriTemizlenir() {
        XCTAssertEqual(evaluate("120101<"), .underMinimumAge)
    }

    func test29SubatArtikYilDogruAyristirilir() {
        // 2012-02-29 geçerli bir tarih → 14 yaşında
        XCTAssertEqual(evaluate("120229"), .underMinimumAge)
    }
}
