import XCTest
@testable import VerifyBlind

/// Canlı benzerlik akışında hangi onaylı karenin 2. aday olarak saklanacağının sözleşmesi.
///
/// Regresyon (2026-09-21, Android, güneşli pencere önü): enclave bir kareye `p_live = 0,987`,
/// saniyeler sonraki kareye `0,534` verdi. "En son onaylananı tut" kuralı iyi kareyi kötüsüyle
/// ezdi, tek kalan aday canlılık eşiğini 0,0164 ile kaçırdı ve meşru kullanıcı reddedildi.
/// Android `57ac180` ile düzeldi; iOS aynı kuralı taşıyordu. Burada sabitlenen: benzerlikten
/// geçen kareler arasından CANLILIĞI EN YÜKSEK olan saklanır.
final class ApprovedFrameSelectionTests: XCTestCase {

    func testFirstApprovalIsAlwaysKept() {
        XCTAssertTrue(
            SimilarityStreamer.shouldKeepApproved(hasApproved: false, newPLive: 0.10, keptPLive: -1),
            "Elde onaylı kare yokken ilk onay — canlılığı düşük olsa bile — saklanmalı")
    }

    func testLowerLivenessDoesNotOverwriteTheBetterFrame() {
        // Sahadaki vaka birebir: 0,987'lik kare 0,534'lükle EZİLMEMELİ.
        XCTAssertFalse(
            SimilarityStreamer.shouldKeepApproved(hasApproved: true, newPLive: 0.534, keptPLive: 0.987),
            "Daha düşük canlılıklı sonraki onay, saklanan iyi kareyi ezmemeli")
    }

    func testHigherLivenessReplacesTheKeptFrame() {
        XCTAssertTrue(
            SimilarityStreamer.shouldKeepApproved(hasApproved: true, newPLive: 0.90, keptPLive: 0.60))
    }

    func testEqualLivenessPrefersTheNewerFrame() {
        // Android ile aynı `>=` — iki platform aynı kareyi seçsin.
        XCTAssertTrue(
            SimilarityStreamer.shouldKeepApproved(hasApproved: true, newPLive: 0.70, keptPLive: 0.70))
    }

    func testMissingLivenessIsKeptOnlyAsALastResort() {
        // p_live gelmezse: hiç yedek yoksa saklanır, skoru bilinen bir yedeği ise ezmez.
        XCTAssertTrue(
            SimilarityStreamer.shouldKeepApproved(hasApproved: false, newPLive: nil, keptPLive: -1))
        XCTAssertFalse(
            SimilarityStreamer.shouldKeepApproved(hasApproved: true, newPLive: nil, keptPLive: 0.40))
    }
}
