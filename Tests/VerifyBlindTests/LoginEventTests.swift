import XCTest
@testable import VerifyBlind

/// 🔴 Enclave `ChoreographyGeneratorTests.GirisTuretmesiSabittir` ile AYNI vektörler (Android
/// `LoginEventTest` de öyle). Biri kırılırsa istemci enclave'in istemediği hareketi yaptırır ve
/// her doğrulama reddedilir.
final class LoginEventTests: XCTestCase {

    func testMatchesEnclaveVectors() {
        XCTAssertEqual(LoginEvent.forNonce("00000000000000000000000000000000"), .smile)
        XCTAssertEqual(LoginEvent.forNonce("b6f1c1c56d0a4b8e9d3a2f5c7e8a9b10"), .mouthOpen)
        XCTAssertEqual(LoginEvent.forNonce("7c9e6679-7425-40de-944b-e07fc1f90ae7"), .mouthOpen)
        XCTAssertEqual(LoginEvent.forNonce("vector-0"), .doubleBlink)
        XCTAssertEqual(LoginEvent.forNonce("A1b2-C3d4"), .smile)
    }

    /// Enclave `UcHareketliGirisTuretmesiSabittir` ile aynı vektörler.
    func testThreeMovesMatchEnclaveVectors() {
        XCTAssertEqual(LoginEvent.forNonceV3("7c9e6679-7425-40de-944b-e07fc1f90ae7"), [.smile, .mouthOpen, .smile])
        XCTAssertEqual(LoginEvent.forNonceV3("vector-0"), [.smile, .mouthOpen, .smile])
        XCTAssertEqual(LoginEvent.forNonceV3("A1b2-C3d4"), [.doubleBlink, .smile, .doubleBlink])
    }

    func testThreeMovesNeverRepeatInARow() {
        for i in 0..<3000 {
            let events = LoginEvent.forNonceV3("n-\(i)")
            XCTAssertEqual(events.count, 3)
            XCTAssertNotEqual(events[0], events[1])
            XCTAssertNotEqual(events[1], events[2])
        }
    }

    func testEmptyNonceAsksForNothing() {
        XCTAssertNil(LoginEvent.forNonce(""))
    }

    func testNeverAsksForAPlainBlinkAndUsesAllThree() {
        var seen: [EventSequencer.Event: Int] = [:]
        for i in 0..<3000 { seen[LoginEvent.forNonce("n-\(i)")!, default: 0] += 1 }
        XCTAssertNil(seen[.blink])
        for event in [EventSequencer.Event.smile, .mouthOpen, .doubleBlink] {
            XCTAssertGreaterThan(seen[event] ?? 0, 850, "\(event)")
        }
    }

    /// Kanıt `face_proof` içinde `choreography_proof` olarak gider; hareketsiz (eski) biçimde alan hiç yazılmaz.
    func testLoginFaceProofCarriesMoveUnderWireName() throws {
        let bare = LoginFaceProof(userSelfie: "s", antiSpoofCrop: "c", deviceMetrics: nil)
        let bareJSON = String(data: try JSONEncoder().encode(bare), encoding: .utf8)!
        XCTAssertFalse(bareJSON.contains("choreography_proof"))

        let move = ChoreographyProof(steps: [ChoreographyProofStep(neutral: ["n"], event: ["e"], attempts: 1)])
        let full = LoginFaceProof(userSelfie: "s", antiSpoofCrop: "c", deviceMetrics: nil, choreographyProof: move)
        let fullJSON = String(data: try JSONEncoder().encode(full), encoding: .utf8)!
        XCTAssertTrue(fullJSON.contains("\"choreography_proof\""))
    }
}
