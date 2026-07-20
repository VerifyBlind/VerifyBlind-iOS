import XCTest
@testable import VerifyBlind

final class SmokeTests: XCTestCase {
    func testConfigLoads() {
        XCTAssertFalse(Config.apiBaseURL.absoluteString.isEmpty, "API_BASE_URL boş")
    }

    func testLogCategoriesExist() {
        XCTAssertEqual(LogCategory.allCases.count, 8)
    }

    /// Regresyon: `Flow.login` kimliği payload'a BAĞLI olmalı. Sabit id ile (eski `rawValue`),
    /// QR kamerası zaten açıkken gelen deep-link'te SwiftUI view kimliğini koruyor,
    /// `LoginFlowView`'un `@StateObject` vm'i yeniden yaratılmıyor ve `initialPayload` sessizce
    /// düşüyordu → kamera açık kalıp doğrulama hiç başlamıyordu.
    func testLoginFlowIdentityChangesWithPayload() {
        let urlA = "https://app.verifyblind.com/request?nonce=A"
        let urlB = "https://app.verifyblind.com/request?nonce=B"

        let manualScan = RootView.Flow.login(payload: nil).id
        let deepLinkA = RootView.Flow.login(payload: urlA).id
        let deepLinkB = RootView.Flow.login(payload: urlB).id

        XCTAssertNotEqual(manualScan, deepLinkA, "Deep-link, açık QR kamerasını preempt edemez")
        XCTAssertNotEqual(deepLinkA, deepLinkB, "Yeni nonce, süren login'i preempt edemez")
        XCTAssertEqual(deepLinkA, RootView.Flow.login(payload: urlA).id, "Aynı payload kararlı id vermeli")
        XCTAssertNotEqual(deepLinkA, RootView.Flow.register.id)
    }
}
