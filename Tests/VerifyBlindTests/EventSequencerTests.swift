import XCTest
import CoreGraphics
@testable import VerifyBlind

/// Olay dizisi mantığı (`EventSequencer`) — kamerasız, zaman dışarıdan verilerek.
///
/// Android `EventCollector` ile AYNI kurallar: nötr kare ancak yüz yerinde, gevşek ve sabitken;
/// istemsiz göz kırpma asla ceza değil; ağız açma istenirken gülümseme yanlış sayılmaz; yüz kaybı
/// yalnız o adımı yeniden başlatır. Kanıtın biçimi enclave'in yapı kuralıyla birebir.
final class EventSequencerTests: XCTestCase {

    private static let frame = CGSize(width: 1080, height: 1920)
    /// Kadrajın ~%37'si — kalite aralığının içinde.
    private static let faceBox = CGRect(x: 340, y: 700, width: 400, height: 500)

    private func sig(smile: Float = 0.1, eyes: Float = 0.95, lip: Float? = nil,
                     box: CGRect = EventSequencerTests.faceBox) -> FaceSignals {
        FaceSignals(yaw: 0, pitch: 0, roll: 0, leftEyeOpen: eyes, rightEyeOpen: eyes, smile: smile,
                    boundingBox: box, leftEye: nil, rightEye: nil, landmarksOK: true, lipOpen: lip)
    }

    /// Diziyi 50 ms'lik karelerle sürer; her kırpma sahte bir JPEG döndürür.
    private struct Driver {
        var seq: EventSequencer
        var now: Double = 1_000
        var signals: [EventSequencer.Signal] = []
        var captures = 0

        init(_ events: [EventSequencer.Event]) {
            seq = EventSequencer(events: events)
            seq.start(now: now)
        }

        mutating func frame(_ s: FaceSignals, ms: Double = 50) {
            now += ms
            var count = captures
            signals += seq.offer(s, frameSize: EventSequencerTests.frame, now: now) {
                count += 1
                return Data([UInt8(count % 250)])
            }
            captures = count
            signals += seq.tick(now: now)
        }

        mutating func hold(_ s: FaceSignals, forMs: Double) {
            let end = now + forMs
            while now < end { frame(s) }
        }

        /// Yüz yok: yalnız saat işler.
        mutating func idle(forMs: Double) {
            let end = now + forMs
            while now < end {
                now += 50
                signals += seq.tick(now: now)
            }
        }
    }

    // MARK: - Nötr kare

    func testNeutralFrameNeedsAStillRelaxedFace() {
        var d = Driver([.blink])
        d.hold(sig(), forMs: 300)
        XCTAssertEqual(d.captures, 0, "Yüz yeni yerleşti — nötr kare henüz alınmamalı")
        XCTAssertEqual(d.seq.phase, .settle)
        d.hold(sig(), forMs: 250)
        XCTAssertEqual(d.captures, 1)
        XCTAssertEqual(d.seq.phase, .event)
        XCTAssertNotNil(d.seq.steps[0].neutral)
    }

    func testSmilingFaceMustRelaxBeforeTheCommand() {
        var d = Driver([.blink])
        d.hold(sig(smile: 0.7), forMs: 1_000)
        XCTAssertEqual(d.captures, 0)
        XCTAssertTrue(d.seq.needsRelax)
        d.hold(sig(), forMs: 600)
        XCTAssertEqual(d.seq.phase, .event)
    }

    /// Yüz boyutu yalnız KALİTE aralığı: çok küçük yüzde hareket istenmez, "yaklaştırın" denir.
    func testTooSmallFaceBlocksTheStep() {
        var d = Driver([.blink])
        d.hold(sig(box: CGRect(x: 440, y: 800, width: 200, height: 260)), forMs: 1_500)
        XCTAssertEqual(d.captures, 0)
        XCTAssertEqual(d.seq.framing, .tooSmall)
    }

    // MARK: - Hareketler

    func testBlinkCompletesTheSequence() {
        var d = Driver([.blink])
        d.hold(sig(), forMs: 600)
        d.frame(sig(eyes: 0.05))
        XCTAssertEqual(d.seq.phase, .afterEvent)
        XCTAssertTrue(d.signals.contains(.stepDone))
        XCTAssertEqual(d.seq.steps[0].events.count, 1)
        d.hold(sig(), forMs: 800)
        XCTAssertEqual(d.signals.last, .completed)
        XCTAssertFalse(d.seq.isActive)
    }

    func testDoubleBlinkNeedsTwoClosings() {
        var d = Driver([.doubleBlink])
        d.hold(sig(), forMs: 600)
        d.frame(sig(eyes: 0.05))
        XCTAssertEqual(d.seq.phase, .event, "Tek kırpma çift kırpmayı bitirmez")
        XCTAssertEqual(d.seq.eventCount, 1)
        d.hold(sig(), forMs: 200)
        d.frame(sig(eyes: 0.05))
        XCTAssertEqual(d.seq.phase, .afterEvent)
        XCTAssertEqual(d.seq.steps[0].events.count, 2, "Enclave çift kırpmada iki kare ister")
    }

    /// Tek kırpmanın ardından sessizlik istemsiz kırpmadır — sessizce sıfırlanır, ceza yok.
    func testLoneBlinkInDoubleBlinkIsForgotten() {
        var d = Driver([.doubleBlink])
        d.hold(sig(), forMs: 600)
        d.frame(sig(eyes: 0.05))
        d.hold(sig(), forMs: 2_200)
        XCTAssertEqual(d.seq.eventCount, 0)
        XCTAssertTrue(d.seq.steps[0].events.isEmpty)
        XCTAssertEqual(d.seq.wrongEvents, 0)
    }

    func testMouthOpenReadsTheLipContour() {
        var d = Driver([.mouthOpen])
        d.hold(sig(lip: 0.02), forMs: 600)
        XCTAssertEqual(d.seq.phase, .event)
        d.frame(sig(lip: 0.10))
        XCTAssertEqual(d.seq.phase, .event, "Yarım açık ağız yetmez")
        d.frame(sig(lip: 0.39))
        XCTAssertEqual(d.seq.phase, .afterEvent)
    }

    /// ML Kit açık ağzı gülümseme sanıyor: ağız açma istenirken gülümseme YANLIŞ değildir.
    func testSmileDuringMouthOpenIsNotWrong() {
        var d = Driver([.mouthOpen])
        d.hold(sig(lip: 0.02), forMs: 600)
        d.frame(sig(smile: 0.9, lip: 0.05))
        XCTAssertEqual(d.seq.wrongEvents, 0)
        XCTAssertEqual(d.seq.phase, .event)
    }

    /// Sürekli gülümseme TEK ceza yazdırır; yeniden nötr görülmeden ikincisi gelmez.
    func testSustainedSmileDuringBlinkChargesOnce() {
        var d = Driver([.blink])
        d.hold(sig(), forMs: 600)
        d.hold(sig(smile: 0.9), forMs: 1_000)
        XCTAssertEqual(d.seq.wrongEvents, 1)
        XCTAssertTrue(d.signals.contains(.wrong(.smile)))
    }

    func testThreeWrongMovesInOneStepEndTheFlow() {
        var d = Driver([.blink])
        d.hold(sig(), forMs: 600)
        for _ in 0..<3 {
            d.frame(sig(smile: 0.9))
            d.hold(sig(), forMs: 200)
        }
        XCTAssertTrue(d.signals.contains(.failed(.tooManyWrong)))
        XCTAssertFalse(d.seq.isActive)
    }

    // MARK: - Süre ve yüz kaybı

    func testEventTimeoutIsReportedAndFails() {
        var d = Driver([.smile])
        d.hold(sig(), forMs: 600)
        d.hold(sig(), forMs: EventSequencer.eventTimeoutMs + 100)
        XCTAssertTrue(d.signals.contains(.failed(.eventTimeout)))
        XCTAssertTrue(d.signals.contains { signal in
            if case .resolved(.smile, _, _, true) = signal { return true }
            return false
        }, "Süresi dolan hareket huniye bildirilmeli")
    }

    /// Yüz kaybı YALNIZ o adımı yeniden başlatır — tamamlanan adımlar korunur.
    func testFaceLossRepeatsOnlyTheCurrentStep() {
        var d = Driver([.blink, .smile])
        d.hold(sig(), forMs: 600)
        d.frame(sig(eyes: 0.05))
        d.hold(sig(), forMs: 800)          // onay → 2. adım yerleşme
        d.hold(sig(), forMs: 600)          // 2. adımın nötr karesi
        XCTAssertEqual(d.seq.completedSteps, 1)
        XCTAssertNotNil(d.seq.steps[1].neutral)

        d.idle(forMs: EventSequencer.faceLostMs + 200)
        XCTAssertTrue(d.signals.contains(.stepReset("face_lost")))
        XCTAssertEqual(d.seq.resets, 1)
        XCTAssertNotNil(d.seq.steps[0].neutral, "Tamamlanan adım silinmemeli")
        XCTAssertEqual(d.seq.steps[0].events.count, 1)
        XCTAssertNil(d.seq.steps[1].neutral)
        XCTAssertEqual(d.seq.phase, .settle)
    }

    // MARK: - Kanıt biçimi

    /// Enclave'in yapı kuralı: adım başına tam bir nötr kare, çift kırpmada iki olay karesi.
    func testProofShapeMatchesTheEnclaveRule() throws {
        var d = Driver([.doubleBlink, .smile, .mouthOpen])
        d.hold(sig(), forMs: 600)
        d.frame(sig(eyes: 0.05)); d.hold(sig(), forMs: 200); d.frame(sig(eyes: 0.05))
        d.hold(sig(), forMs: 800)
        d.hold(sig(), forMs: 600)
        d.frame(sig(smile: 0.9))
        d.hold(sig(), forMs: 800)
        d.hold(sig(lip: 0.02), forMs: 600)
        d.frame(sig(lip: 0.4))
        d.hold(sig(), forMs: 800)
        XCTAssertEqual(d.signals.last, .completed)

        let proof = LivenessViewModel.makeProof(d.seq, elapsedMs: 9_000)
        XCTAssertEqual(proof.version, 2)
        XCTAssertEqual(proof.steps.map { $0.neutral.count }, [1, 1, 1])
        XCTAssertEqual(proof.steps.map { $0.event.count }, [2, 1, 1])
        XCTAssertEqual(proof.steps.map { $0.attempts ?? 0 }, [1, 1, 1])
        XCTAssertTrue(proof.trace?.hasPrefix("0.0 start double_blink,smile,mouth_open;") ?? false)

        // Anahtarlar enclave modeliyle BİREBİR (ChoreographyModels.cs).
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as? [String: Any]
        for key in ["version", "steps", "elapsed_ms", "resets", "wrong_events", "trace"] {
            XCTAssertNotNil(json?[key], "\(key) alanı olmalı")
        }
        let step = (json?["steps"] as? [[String: Any]])?.first
        for key in ["neutral", "event", "attempts"] {
            XCTAssertNotNil(step?[key], "\(key) alanı olmalı")
        }
    }

    func testPayloadCarriesProofUnderExactName() throws {
        var payload = SecurePayload(sod: "", dg1: "", activeSig: "", userPubKey: "")
        payload.choreographyProof = ChoreographyProof(steps: [])
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertTrue(json.contains("\"ChoreographyProof\""))
    }

    func testHandshakeParsesEventsAndIgnoresOldStops() throws {
        let fresh = #"{"nonce":"n","timestamp":1,"nonce_signature":"s","choreography":{"version":2,"events":[4,1,3]}}"#
        XCTAssertEqual(try JSONDecoder().decode(HandshakeResponse.self, from: Data(fresh.utf8)).choreography?.events,
                       [4, 1, 3])
        // Mesafe dönemi sunucusu (sürüm 1) `events` göndermez → dizi yok → ekran açık hatayla durur.
        let old = #"{"nonce":"n","timestamp":1,"nonce_signature":"s","choreography":{"version":1,"stops":[{"pos":3,"event":0}]}}"#
        XCTAssertNil(try JSONDecoder().decode(HandshakeResponse.self, from: Data(old.utf8)).choreography?.events)
    }

    /// Huni adım adları Android ve sunucuyla AYNI (RegisterFlowSteps).
    func testTelemetryStepNamesMatchTheServer() {
        XCTAssertEqual(EventSequencer.Event.blink.telemetryStep.rawValue, "gesture_blink")
        XCTAssertEqual(EventSequencer.Event.smile.telemetryStep.rawValue, "gesture_smile")
        XCTAssertEqual(EventSequencer.Event.mouthOpen.telemetryStep.rawValue, "gesture_mouth_open")
        XCTAssertEqual(EventSequencer.Event.doubleBlink.telemetryStep.rawValue, "gesture_double_blink")
    }

    /// Sayılar Android `EventCollector` ile AYNI — iOS'un kendi kalibrasyonu YOK.
    func testConstantsMatchAndroid() {
        XCTAssertEqual(EventSequencer.settleTimeoutMs, 20_000)
        XCTAssertEqual(EventSequencer.eventTimeoutMs, 12_000)
        XCTAssertEqual(EventSequencer.maxWrong, 5)
        XCTAssertEqual(EventSequencer.maxWrongPerStep, 3)
        XCTAssertEqual(EventSequencer.maxResets, 3)
        XCTAssertEqual(EventSequencer.eyeClosed, 0.20)
        XCTAssertEqual(EventSequencer.smileOn, 0.8)
        XCTAssertEqual(EventSequencer.smileNeutral, 0.4)
        XCTAssertEqual(EventSequencer.mouthOpenMin, 0.20)
        XCTAssertEqual(EventSequencer.doubleBlinkWindowMs, 2_000)
        XCTAssertEqual(EventSequencer.minFaceFraction, 0.28)
        XCTAssertEqual(EventSequencer.maxFaceFraction, 0.80)
    }

    // MARK: - Kırpma

    func testFaceCropIsCenteredSquare() {
        let r = FaceCrop.squareAround(CGRect(x: 340, y: 760, width: 400, height: 400), width: 1080, height: 1920)
        XCTAssertEqual(r.width, 880)
        XCTAssertEqual(r.width, r.height)
        XCTAssertEqual(r.midX, 540)
        XCTAssertEqual(r.midY, 960)
    }

    /// Yüz kenardayken kırpma KAYDIRILIR, kesilmez; kadrajdan büyükse kısa kenara küçülür.
    func testFaceCropStaysInsideTheFrame() {
        let edge = FaceCrop.squareAround(CGRect(x: 0, y: 0, width: 300, height: 300), width: 1080, height: 1920)
        XCTAssertEqual(edge.minX, 0)
        XCTAssertEqual(edge.minY, 0)
        XCTAssertEqual(edge.width, 660)
        let huge = FaceCrop.squareAround(CGRect(x: 0, y: 200, width: 1080, height: 1300), width: 1080, height: 1920)
        XCTAssertEqual(huge.width, 1080)
        XCTAssertTrue(huge.maxX <= 1080 && huge.maxY <= 1920)
    }
}
