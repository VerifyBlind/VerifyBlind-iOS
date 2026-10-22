import XCTest
@testable import VerifyBlind

/// Canlılık başarısızlığının Sentry mesajı ölçülen değerlerden BAĞIMSIZ olmalı.
///
/// Regresyon zemini: mesaj `bestScore=84% [luma=… sharp=…]` taşıyordu; Sentry mesajsız olayları
/// metinden grupladığı için her deneme ayrı bir issue açıyordu (Android'de VERIFYBLIND-ANDROID-1S).
final class LivenessFailureReportTests: XCTestCase {

    func testMessageIsIndependentOfMeasuredValues() {
        let a = LivenessViewModel.failureReport(reason: .tooManyErrors, bestScore: 0.84,
                                                frameMetrics: "luma=103 sharp=474", diagnostics: "luma=103")
        let b = LivenessViewModel.failureReport(reason: .tooManyErrors, bestScore: 0.12,
                                                frameMetrics: nil, diagnostics: "luma=40")
        XCTAssertEqual(a.message, b.message)
        XCTAssertEqual(a.message, "Liveness başarısız (tooManyErrors)")
    }

    func testBoundedReasonStaysInMessage() {
        // Sebep sınırlı bir enum: ayrı issue olarak görünmesi işe yarar.
        let timeout = LivenessViewModel.failureReport(reason: .gestureTimeout, bestScore: 0,
                                                      frameMetrics: nil, diagnostics: "")
        XCTAssertTrue(timeout.message.contains("gestureTimeout"))
    }

    func testValuesMoveToExtras() {
        let r = LivenessViewModel.failureReport(reason: .matchFailed, bestScore: 0.84,
                                                frameMetrics: "luma=103", diagnostics: "faces=3 luma=103")
        XCTAssertEqual(r.extras["best_score"], "84%")
        XCTAssertEqual(r.extras["frame_metrics"], "luma=103")
        XCTAssertEqual(r.extras["diagnostics"], "faces=3 luma=103")
        XCTAssertFalse(r.message.contains("84"))
    }

    func testMissingFrameMetricsIsExplicit() {
        let r = LivenessViewModel.failureReport(reason: .noSelfie, bestScore: 0, frameMetrics: nil, diagnostics: "")
        XCTAssertEqual(r.extras["frame_metrics"], "kare ölçüsü yok")
    }
}
