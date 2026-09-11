import XCTest
@testable import VerifyBlind

/// Doğrulama bağlantısının kabul kapısı.
///
/// Regresyon zemini (parite denetimi 2026-09-03, D-1): ayrıştırıcı HERHANGİ bir URL'deki `nonce`
/// parametresini kabul ediyordu ve deep-link girişi yalnız host'a bakıyordu. Android baştan beri
/// şema + host (+ `/request`) arıyor. Nonce'u sunucu zaten doğruladığı için bu bir kimlik açığı
/// değildi; ama başka bir siteye ait bir QR'ı "geçersiz kod" demek yerine sessizce login akışına
/// sokmak yanlış davranış.
///
/// Kural iki yol tarafından PAYLAŞILIR (`isVerifyURL`): taranan QR ve gelen deep-link aynı kapıdan
/// geçer — biri gevşerse ötekisi de gevşer.
final class QRPayloadParserTests: XCTestCase {

    private let valid = "https://app.verifyblind.com/request?nonce=abc123&pk_hash=deadbeef"

    // MARK: - Kabul

    func testVerifyLinkIsParsed() {
        let result = QRPayloadParser.parse(valid)
        XCTAssertEqual(result?.nonce, "abc123")
        XCTAssertEqual(result?.pkHash, "deadbeef")
        XCTAssertNil(result?.returnUrl)
    }

    func testAppReturnUrlIsCarried() {
        let result = QRPayloadParser.parse(valid + "&return=verifyblinddemo%3A%2F%2Fcallback")
        XCTAssertEqual(result?.returnUrl, "verifyblinddemo://callback")
    }

    func testHostComparisonIsCaseInsensitive() {
        XCTAssertNotNil(QRPayloadParser.parse("https://APP.VerifyBlind.com/request?nonce=abc123"))
    }

    /// JSON yedeği (eski partner üretimleri) URL kuralından etkilenmemeli.
    func testJsonFallbackStillWorks() {
        let result = QRPayloadParser.parse(#"{"nonce":"abc123","pk_hash":"deadbeef"}"#)
        XCTAssertEqual(result?.nonce, "abc123")
        XCTAssertEqual(result?.pkHash, "deadbeef")
    }

    // MARK: - Ret

    func testForeignHostIsRejected() {
        XCTAssertNil(QRPayloadParser.parse("https://evil.example.com/request?nonce=abc123"))
    }

    func testPlainHttpIsRejected() {
        XCTAssertNil(QRPayloadParser.parse("http://app.verifyblind.com/request?nonce=abc123"))
    }

    func testWrongPathIsRejected() {
        // Aynı host'taki başka bir sayfanın bağlantısı login akışını AÇMAMALI.
        XCTAssertNil(QRPayloadParser.parse("https://app.verifyblind.com/kampanya?nonce=abc123"))
    }

    func testMissingNonceIsRejected() {
        XCTAssertNil(QRPayloadParser.parse("https://app.verifyblind.com/request?pk_hash=deadbeef"))
        XCTAssertNil(QRPayloadParser.parse("https://app.verifyblind.com/request?nonce="))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(QRPayloadParser.parse("merhaba dünya"))
        XCTAssertNil(QRPayloadParser.parse(""))
    }

    // MARK: - Deep-link girişiyle paylaşılan kural

    func testIsVerifyURLMatchesTheParserGate() {
        XCTAssertTrue(QRPayloadParser.isVerifyURL(URL(string: valid)!))
        XCTAssertFalse(QRPayloadParser.isVerifyURL(URL(string: "https://verifyblind.com/request?nonce=a")!))
        XCTAssertFalse(QRPayloadParser.isVerifyURL(URL(string: "verifyblind://request?nonce=a")!))
        XCTAssertFalse(QRPayloadParser.isVerifyURL(URL(string: "https://app.verifyblind.com/sss")!))
    }
}
