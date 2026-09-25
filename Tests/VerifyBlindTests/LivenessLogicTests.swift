import XCTest
import CoreGraphics
@testable import VerifyBlind

/// Liveness'ın saf/durumlu parçaları (kamera gerektirmez): lokalizasyon, geri bildirim kutusu,
/// çip imza yapısı, gülümseme eşikleri, hizalama.
///
/// Hareket KARARI artık `EventSequencer`'da; onun testleri `EventSequencerTests`'te. Kafa çevirme
/// ve eski jest zamanlayıcısı (2026-09-25) testleriyle birlikte kalktı.
final class LivenessLogicTests: XCTestCase {

    /// Ekranda gösterilen her metin lokalize edilmeli — uygulama İngilizceyken Türkçe metin
    /// görünüyordu (kullanıcı geri bildirimi 2026-08-21: liveness süresi dolunca TR mesaj).
    func testLivenessStringsAreLocalized() {
        let keys = ["liveness_timeout_title", "liveness_timeout_message",
                    "liveness_too_many_errors_title", "liveness_too_many_errors_message",
                    "liveness_selfie_error_title", "liveness_selfie_error_message",
                    "liveness_match_failed_title", "liveness_match_failed_message",
                    "liveness_camera_permission_title", "liveness_camera_permission_body",
                    "liveness_face_smile_relax",
                    "liveness_thumb_chip", "liveness_thumb_selfie",
                    "liveness_wrong_move_detail", "liveness_did_smile", "liveness_did_mouth_open",
                    "liveness_face_blink", "liveness_face_double_blink",
                    "liveness_face_smile", "liveness_face_mouth_open",
                    "liveness_ev_hint_blink", "liveness_ev_hint_double_blink",
                    "liveness_ev_hint_smile", "liveness_ev_hint_mouth_open",
                    "liveness_ev_place", "liveness_ev_closer", "liveness_ev_farther",
                    "liveness_ev_hold", "liveness_ev_hold_hint", "liveness_ev_relax_hint",
                    "liveness_ev_again", "liveness_ev_reset_face",
                    "liveness_ev_resets_title", "liveness_ev_resets_message",
                    "liveness_ev_settle_timeout_title", "liveness_ev_settle_timeout_message",
                    "liveness_ev_missing", "liveness_error_title",
                    "login_face_move_retry", "login_face_move_failed_message",
                    "liveness_guide_title", "liveness_guide_light",
                    "liveness_guide_hold", "liveness_guide_accessories", "liveness_guide_start",
                    "feedback_prompt_title", "feedback_prompt_message",
                    "feedback_prompt_yes", "feedback_prompt_no", "feedback_subject_card_add",
                    "feedback_step_mrz", "feedback_step_nfc", "feedback_step_liveness", "feedback_step_submit",
                    "scan_mrz_instruction", "scan_mrz_subtitle",
                    "scan_mrz_instruction_prefix", "scan_mrz_instruction_emphasis",
                    "scan_mrz_instruction_suffix", "scan_mrz_card_hint_a11y",
                    "btn_retry", "btn_cancel", "btn_close"]
        for key in keys {
            XCTAssertNotEqual(L.t(key), key, "Eksik lokalizasyon anahtarı: \(key)")
        }
    }

    /// Geri bildirim kutusu: yalnız HATA sonrası, ve aralık kadar bir sıklık sınırıyla.
    /// (Aralık şu an TEST FAZI değeri; bkz. FlowFeedbackPrompt.)
    func testFeedbackPromptIsRateLimited() {
        let now = Date()
        UserDefaults.standard.removeObject(forKey: "feedback_prompt_last_shown")
        XCTAssertTrue(FlowFeedbackPrompt.shouldOffer(now: now), "İlk hatada sorulabilmeli")

        FlowFeedbackPrompt.markShown(now: now)
        XCTAssertFalse(FlowFeedbackPrompt.shouldOffer(now: now.addingTimeInterval(5)),
                       "Aynı olaydan doğan ikinci tetik yutulmalı")
        XCTAssertTrue(FlowFeedbackPrompt.shouldOffer(now: now.addingTimeInterval(120)),
                      "AYRI bir deneme yeniden sorabilmeli (test fazı aralığı)")

        UserDefaults.standard.removeObject(forKey: "feedback_prompt_last_shown")
    }

    /// Konu satırı kullanıcının takıldığı adımı adıyla taşımalı — "nerede kaldınız?" sormayalım.
    func testFeedbackSubjectNamesTheStep() {
        let subject = FlowFeedbackPrompt.subject(for: .nfc)
        XCTAssertFalse(subject.isEmpty)
        XCTAssertNotEqual(subject, "feedback_subject_card_add")
        XCTAssertTrue(subject.contains(L.t("feedback_step_nfc")), "Konu adımı içermeli: \(subject)")
    }

    // MARK: - Çip imza yapısı (ChipSignatureCheck)
    // İstemci kontrolü SUNUCUDAN DAHA KATI OLAMAZ: yalnız yapısal olarak imkânsız blokları eler.

    func testIsoImplicitTrailerBlockIsReadable() {
        var block = [UInt8](repeating: 0, count: 192)
        block[0] = 0x6A; block[191] = 0xBC
        XCTAssertTrue(ChipSignatureCheck.looksLikeSignatureBlock(block))
    }

    func testIsoExplicitTrailerBlockIsReadable() {
        var block = [UInt8](repeating: 0, count: 192)
        block[0] = 0x4A; block[190] = 0x34; block[191] = 0xCC
        XCTAssertTrue(ChipSignatureCheck.looksLikeSignatureBlock(block))
    }

    func testPkcs1BlockIsReadable() {
        var block = [UInt8](repeating: 0, count: 192)
        block[0] = 0x01; block[1] = 0xFF
        XCTAssertTrue(ChipSignatureCheck.looksLikeSignatureBlock(block))
    }

    /// 2026-08-24'te gerçekten gözlenen bozuk okuma: hdr=4A, trailer=C1AD.
    func testCorruptedReadBlockIsRejected() {
        var block = [UInt8](repeating: 0, count: 192)
        block[0] = 0x4A; block[190] = 0xC1; block[191] = 0xAD
        XCTAssertFalse(ChipSignatureCheck.looksLikeSignatureBlock(block))
    }

    func testMissingInputLeavesTheDecisionToTheServer() {
        XCTAssertTrue(ChipSignatureCheck.isReadable(dg15: nil, signature: nil))
        XCTAssertTrue(ChipSignatureCheck.isReadable(dg15: Data(), signature: Data()))
        // Ayrıştırılamayan DG15 → şüphede kullanıcıyı durdurma.
        XCTAssertTrue(ChipSignatureCheck.isReadable(dg15: Data([1, 2, 3]),
                                                    signature: Data(repeating: 0, count: 192)))
    }

    func testUnreadableSignatureIsNotAnUnsupportedDocument() {
        let verdict = DocumentSupport.evaluate(
            issuingState: "TUR", documentCode: "I",
            faceImage: Data([0xFF, 0xD8, 0xFF]), dg15: Data([1, 2, 3]), activeSig: Data([4, 5, 6]),
            chipSignatureReadable: false)
        XCTAssertEqual(verdict, .chipSignatureUnreadable)
    }

    func testGestureFeedbackSoundsAreBundled() {
        for name in ["liveness_ok", "liveness_wrong", "liveness_done"] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "wav"),
                            "Jest geri bildirim sesi pakette yok: \(name).wav")
        }
    }

    // MARK: - ML Kit: mutlak olasılık eşikleri

    /// Eşikler Android ile AYNI sayı olmalı — iOS'un kendi kalibrasyonu YOK. Olay dizisinin
    /// eşikleri de aynı değerleri kullanıyor (bkz. `EventSequencerTests.testConstantsMatchAndroid`).
    func testThresholdsMatchAndroid() {
        XCTAssertEqual(LivenessGestureDetector.smileThreshold, 0.8)
        XCTAssertEqual(LivenessGestureDetector.smileRelaxBelow, 0.4)
        XCTAssertEqual(EventSequencer.smileOn, LivenessGestureDetector.smileThreshold)
        XCTAssertEqual(EventSequencer.smileNeutral, LivenessGestureDetector.smileRelaxBelow)
    }

    /// Nötr bandı gülümseme eşiğinden dar: 0.4–0.8 arası ne nötr ne gülümseme. Bu ara bant,
    /// gülümsemenin bir GEÇİŞ olarak ölçülmesini sağlayan histerezistir.
    func testSmileNeutralBand() {
        XCTAssertTrue(LivenessGestureDetector.isSmileNeutral(0))
        XCTAssertTrue(LivenessGestureDetector.isSmileNeutral(0.39))
        XCTAssertFalse(LivenessGestureDetector.isSmileNeutral(0.4))
        XCTAssertFalse(LivenessGestureDetector.isSmileNeutral(0.6), "ara bant nötr DEĞİL")
        XCTAssertFalse(LivenessGestureDetector.isSmileNeutral(-1), "kare yoksa nötr sayılmaz")
    }

    /// `FaceAligner` açıyı `atan2(dy, dx)` ile buluyor → göz sırası ters gelirse yüz 180° DÖNÜK
    /// hizalanır ve embedding çöp olur. Vision ile ML Kit'in sol/sağ konvansiyonu aynı olmak
    /// zorunda değil, üstelik ön kamera aynası hangi gözün solda kaldığını da çevirir.
    func testAlignmentIsIndependentOfEyeOrder() {
        let a = CGPoint(x: 30, y: 50)
        let b = CGPoint(x: 80, y: 54)
        XCTAssertEqual(FaceAligner.params(leftEye: a, rightEye: b),
                       FaceAligner.params(leftEye: b, rightEye: a),
                       "Göz sırası hizalamayı DEĞİŞTİRMEMELİ")
        XCTAssertFalse(FaceAligner.params(leftEye: a, rightEye: b).usedFallback)
    }
}
