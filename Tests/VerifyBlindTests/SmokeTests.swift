import XCTest
@testable import VerifyBlind

final class SmokeTests: XCTestCase {
    func testConfigLoads() {
        XCTAssertFalse(Config.apiBaseURL.absoluteString.isEmpty, "API_BASE_URL boş")
    }

    func testLogCategoriesExist() {
        XCTAssertEqual(LogCategory.allCases.count, 8)
    }
}
