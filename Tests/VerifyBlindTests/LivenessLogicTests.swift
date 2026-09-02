import XCTest
import CoreGraphics
@testable import VerifyBlind

/// Liveness jest mantığı — saf/durumlu parçalar (kamera gerektirmez).
///
/// Jest kararı ML Kit'in EĞİTİLMİŞ olasılıklarına dayanır. Buradaki testler o sözleşmeyi sabitler:
/// eşiklerin Android ile aynı sayı olduğunu, eşik altındaki hiçbir değerin gülümseme sayılmadığını
/// ve gülümseme cezasının yalnız nötrden bir GEÇİŞ olarak yazıldığını.
///
/// Vision döneminin göreceli `SmileDetector`/`BlinkDetector` testleri, o sınıflarla birlikte
/// kaldırıldı (2026-08-25, cihazda doğrulandıktan sonra).
final class LivenessLogicTests: XCTestCase {

    // MARK: - Zamanlama ve hata bütçesi sözleşmesi

    func testTimingConstants() {
        // Hareket başına süre HER BAŞARILI HAREKETTE sıfırlanır → ilerleyen kullanıcı zamana yenilmez.
        XCTAssertEqual(LivenessViewModel.gestureTimeout, 15)
        // Kötüye kullanımın ASIL sınırı: sayılabilir hata bütçesi (eskiden sınırsızdı).
        XCTAssertEqual(LivenessViewModel.maxWrongAttempts, 5)
    }

    /// REGRESYON: sabit 60sn'lik oturum tavanı, 5 hareket × 15sn = 75sn'lik hareket bütçesini
    /// karşılamıyordu — "her harekete 15 saniye" sözü 4. harekette sessizce bozuluyordu.
    /// Tavan artık bütçeden türetilir; ikisi bir daha çelişemez.
    /// ⚠️ `LivenessViewModel` ÖRNEKLEMEZ. Örneklemek `FaceEmbedder`'ı, o da MobileFaceNet CoreML
    /// modelini yüklüyor; bu test döngüde üç kez yaptığı için simülatörde asılıyor ve test
    /// sürecini öldürüyordu (CI: 497 saniye, 33 testin yalnız 16'sı koştu). Doğrulanan şey saf
    /// aritmetik — kamera da sinir ağı da gerekmiyor.
    func testSessionCapCoversTheGestureBudget() {
        for count in [3, 5, 7] {
            let cap = LivenessViewModel.sessionTimeout(challengeCount: count)
            // Dizi her hâlükârda 5'e tamamlanır → tavan en az 5 hareketi karşılamalı.
            let gestures = Double(max(count, 5))
            XCTAssertGreaterThanOrEqual(
                cap, LivenessViewModel.gestureTimeout * gestures,
                "Tavan (\(cap)sn) \(gestures) hareketin bütçesini karşılamıyor")
            // Üstüne onay animasyonu / ceza / gevşeme payı da olmalı.
            XCTAssertEqual(cap,
                           LivenessViewModel.gestureTimeout * gestures + LivenessViewModel.sessionOverhead)
        }
    }

    /// Ekranda gösterilen her metin lokalize edilmeli — uygulama İngilizceyken Türkçe metin
    /// görünüyordu (kullanıcı geri bildirimi 2026-08-21: liveness süresi dolunca TR mesaj).
    func testLivenessStringsAreLocalized() {
        let keys = ["liveness_wrong_move", "liveness_perform_action",
                    "liveness_timeout_title", "liveness_timeout_message",
                    "liveness_too_many_errors_title", "liveness_too_many_errors_message",
                    "liveness_selfie_error_title", "liveness_selfie_error_message",
                    "liveness_match_failed_title", "liveness_match_failed_message",
                    "liveness_camera_permission_title", "liveness_camera_permission_body",
                    "liveness_face_smile_relax", "liveness_face_smile_relax_hint",
                    "liveness_thumb_chip", "liveness_thumb_selfie",
                    "liveness_wrong_move_detail", "liveness_did_face_left", "liveness_did_face_right",
                    "liveness_did_smile",
                    "feedback_prompt_title", "feedback_prompt_message",
                    "feedback_prompt_yes", "feedback_prompt_no", "feedback_subject_card_add",
                    "feedback_step_mrz", "feedback_step_nfc", "feedback_step_liveness", "feedback_step_submit",
                    "scan_mrz_instruction", "scan_mrz_subtitle",
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

    // MARK: - ML Kit geçişi: mutlak olasılık eşikleri ve gülümseme ceza kapısı

    /// `FaceSignals` üretici — yalnız ilgilenilen alanı verip gerisini nötr bırakır.
    private func sig(smile: Float = 0, yaw: Float = 0,
                     leftEyeOpen: Float = 1, rightEyeOpen: Float = 1) -> FaceSignals {
        FaceSignals(yaw: yaw, pitch: 0, roll: 0,
                    leftEyeOpen: leftEyeOpen, rightEyeOpen: rightEyeOpen, smile: smile,
                    boundingBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                    leftEye: nil, rightEye: nil)
    }

    /// Eşikler Android `LivenessActivity` ile AYNI sayı olmalı — iOS'un kendi kalibrasyonu YOK.
    /// Bu test sapmayı yakalar: bir eşik "iOS'ta biraz farklı" olmaya başlarsa parite biter.
    func testThresholdsMatchAndroid() {
        XCTAssertEqual(LivenessGestureDetector.yawThreshold, 20)
        XCTAssertEqual(LivenessGestureDetector.blinkThreshold, 0.1)
        XCTAssertEqual(LivenessGestureDetector.smileThreshold, 0.8)
        XCTAssertEqual(LivenessGestureDetector.smileRelaxBelow, 0.4)
    }

    /// ASIL REGRESYON (kullanıcı geri bildirimi 2026-08-25): asık yüz "gülümsediniz" sayılıyordu.
    /// Sinyal artık ham oran değil ML Kit olasılığı; eşiğin ALTINDAKİ hiçbir değer smile olamaz.
    func testNoSmileBelowThreshold() {
        for p in stride(from: Float(0), through: 0.79, by: 0.04) {
            XCTAssertNotEqual(LivenessGestureDetector.detect(sig(smile: p)), .smile,
                              "olasılık \(p) gülümseme sayılmamalı")
        }
        XCTAssertEqual(LivenessGestureDetector.detect(sig(smile: 0.9)), .smile)
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

    /// ASIL REGRESYON: kullanıcı "hata mesajı kalkar kalkmaz aynısı tekrar geliyor, beş hakkın
    /// tamamı yanıyor" dedi. Sürekli yüksek okunan bir gülümseme sinyali TEK ceza yazdırmalı.
    func testSustainedSmileChargesOnlyOnePenalty() {
        var gate = SmileEdgeGate()
        gate.observe(0.1)                                  // nötr görüldü → ceza mümkün
        XCTAssertTrue(gate.consumeIfArmed(), "İlk ceza yazılabilmeli")

        for _ in 0..<90 { gate.observe(0.95) }             // ~3 saniye kesintisiz gülümseme
        XCTAssertFalse(gate.consumeIfArmed(), "Nötr yeniden görülmeden ikinci ceza yazılamaz")
    }

    /// Komut geldiğinde kullanıcı zaten gülümsüyorsa (ya da öyle ölçülüyorsa) ceza yazılamaz —
    /// onu gülümsemez hâlde HİÇ görmedik.
    func testPenaltyRequiresHavingSeenNeutral() {
        var gate = SmileEdgeGate()
        for _ in 0..<60 { gate.observe(0.95) }
        XCTAssertFalse(gate.consumeIfArmed())
    }

    /// Kapı kalıcı değil: kullanıcı nötre dönerse gerçek bir sonraki gülümseme yine sayılır.
    /// Ceza bütçesinin kötüye kullanıma karşı işlevi korunuyor.
    func testNeutralAgainReArmsThePenalty() {
        var gate = SmileEdgeGate()
        gate.observe(0.1)
        XCTAssertTrue(gate.consumeIfArmed())
        gate.observe(0.2)                                  // yeniden nötr
        XCTAssertTrue(gate.consumeIfArmed(), "Nötre dönen kullanıcı yeniden ceza alabilmeli")
    }

    func testGateResetsOnNewSession() {
        var gate = SmileEdgeGate()
        gate.observe(0.1)
        gate.reset()
        XCTAssertFalse(gate.consumeIfArmed(), "Yeni oturumda nötr baştan görülmeli")
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
