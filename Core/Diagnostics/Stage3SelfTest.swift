import CoreGraphics

/// Aşama 3 (Camera/OCR/Liveness) deterministik doğrulaması.
///
/// Kamera/Vision/CoreML etkileşimli kısımları cihazda test ekranlarıyla doğrulanır; bu self-test
/// yalnızca SAF mantığı kanıtlar: MRZ ayrıştırma (TD1/TD3 + check digit + OCR auto-fix), jest
/// tespiti + kalite skoru, yüz hizalama (similarity transform) ve kosinüs/L2. CI'da KOŞMAZ;
/// cihazda dev env butonuyla çalışır. Bkz. `feedback_ios_codemagic_no_ci_tests`.
/// `SelfTestResult` `Stage1SelfTest.swift`'te tanımlı.
enum Stage3SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        // ── MRZ: TD1 (kimlik) — ICAO Doc 9303 örnek ──
        r.append(check("MRZ TD1 parse (ICAO örnek → ID)") {
            let mrz = """
            I<UTOD231458907<<<<<<<<<<<<<<<
            7408122F1204159UTO<<<<<<<<<<<6
            ERIKSSON<<ANNA<MARIA<<<<<<<<<<
            """
            let p = MRZParser.parse(mrz)
            let ok = p?.documentNumber == "D23145890" && p?.dateOfBirth == "740812"
                && p?.dateOfExpiry == "120415" && p?.documentType == "ID"
            return (ok, p.map { "\($0.documentNumber)/\($0.dateOfBirth)/\($0.dateOfExpiry)/\($0.documentType)" } ?? "nil")
        })

        // ── MRZ: TD3 (pasaport) ──
        r.append(check("MRZ TD3 parse (→ PASSPORT)") {
            let mrz = """
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            """
            let p = MRZParser.parse(mrz)
            let ok = p?.documentNumber == "L898902C3" && p?.dateOfBirth == "740812"
                && p?.dateOfExpiry == "120415" && p?.documentType == "PASSPORT"
            return (ok, p.map { "\($0.documentNumber)/\($0.documentType)" } ?? "nil")
        })

        // ── Check digit (ICAO 7-3-1) bilinen vektörler ──
        r.append(check("checkDigit: L898902C<=3, 740812=2, 120415=9") {
            let a = MRZParser.checkDigit("L898902C<")
            let b = MRZParser.checkDigit("740812")
            let c = MRZParser.checkDigit("120415")
            return (a == 3 && b == 2 && c == 9, "L..=\(a) dob=\(b) exp=\(c)")
        })

        // ── OCR auto-fix: O→0 checksum ile düzeltilir ──
        r.append(check("validateAndFix: 74O812 + check 2 → 740812") {
            let fixed = MRZParser.validateAndFix("74O812", "2")
            return (fixed == "740812", fixed ?? "nil")
        })

        r.append(check("validateAndFix: düzeltilemez → nil") {
            let fixed = MRZParser.validateAndFix("000000", "9")
            return (fixed == nil, fixed ?? "nil (beklenen)")
        })

        // ── Jest tespiti ──
        r.append(check("detect: yaw 25 → faceLeft") {
            let s = signals(yaw: 25)
            return (LivenessGestureDetector.detect(s) == .faceLeft, "\(String(describing: LivenessGestureDetector.detect(s)))")
        })
        r.append(check("detect: yaw -25 → faceRight") {
            (LivenessGestureDetector.detect(signals(yaw: -25)) == .faceRight, "ok")
        })
        r.append(check("detect: smile 0.9 → smile") {
            (LivenessGestureDetector.detect(signals(smile: 0.9)) == .smile, "ok")
        })
        r.append(check("detect: iki göz 0.05 → blink") {
            (LivenessGestureDetector.detect(signals(leftEyeOpen: 0.05, rightEyeOpen: 0.05)) == .blink, "ok")
        })
        r.append(check("detect: nötr → nil") {
            (LivenessGestureDetector.detect(signals(smile: 0.5)) == nil, "ok")
        })

        // ── Kalite skoru ──
        r.append(check("qualityScore: merkez/frontal/büyük → 100") {
            let s = signals(boundingBox: CGRect(x: 300, y: 300, width: 400, height: 400))
            let q = LivenessGestureDetector.qualityScore(s, imageSize: CGSize(width: 1000, height: 1000))
            return (q == 100, "\(q)")
        })
        r.append(check("qualityScore: yaw 30 → 60") {
            let s = signals(yaw: 30, boundingBox: CGRect(x: 300, y: 300, width: 400, height: 400))
            let q = LivenessGestureDetector.qualityScore(s, imageSize: CGSize(width: 1000, height: 1000))
            return (approx(q, 60, tol: 0.01), "\(q)")
        })

        // ── Yüz hizalama (similarity transform scalar) ──
        r.append(check("FaceAligner.params: yatay gözler → scale≈0.3524, açı≈0.33°") {
            let p = FaceAligner.params(leftEye: CGPoint(x: 0, y: 0), rightEye: CGPoint(x: 100, y: 0))
            let ok = !p.usedFallback && approx(Float(p.scale), 0.35241, tol: 0.001)
                && approx(Float(p.angleDegrees), 0.325, tol: 0.05)
            return (ok, "scale=\(p.scale) angle=\(p.angleDegrees)")
        })
        r.append(check("FaceAligner.params: göz yok → fallback") {
            let p = FaceAligner.params(leftEye: nil, rightEye: nil)
            return (p.usedFallback && p.scale == 1 && p.angleDegrees == 0, "fallback")
        })
        r.append(check("FaceAligner.params: gözler çok yakın → fallback") {
            let p = FaceAligner.params(leftEye: CGPoint(x: 0, y: 0), rightEye: CGPoint(x: 3, y: 0))
            return (p.usedFallback, "dist<5 fallback")
        })

        // ── Kosinüs / L2 ──
        r.append(check("cosineSimilarity: özdeş → 1, dik → 0") {
            let same = FaceEmbedder.cosineSimilarity([1, 0, 0], [1, 0, 0])
            let orth = FaceEmbedder.cosineSimilarity([1, 0], [0, 1])
            return (approx(same, 1, tol: 1e-5) && approx(orth, 0, tol: 1e-5), "same=\(same) orth=\(orth)")
        })
        r.append(check("l2Normalize: [3,4] → [0.6,0.8]") {
            let n = FaceEmbedder.l2Normalize([3, 4])
            return (approx(n[0], 0.6, tol: 1e-5) && approx(n[1], 0.8, tol: 1e-5), "\(n)")
        })

        // ── BlinkDetector (göreceli kapan→açıl) ──
        r.append(check("BlinkDetector: aç→kapa→aç → blink") {
            let b = BlinkDetector()
            for _ in 0..<5 { _ = b.feed(0.9) }   // baseline kur (açık)
            _ = b.feed(0.3)                       // kapan
            let fired = b.feed(0.9)               // açıl → blink
            return (fired, fired ? "fired" : "fire yok")
        })
        r.append(check("BlinkDetector: sabit açık → blink YOK") {
            let b = BlinkDetector()
            var any = false
            for _ in 0..<10 { if b.feed(0.9) { any = true } }
            return (!any, any ? "yanlis fire" : "ok")
        })

        // ── CoreML model varlığı (bilgilendirici — model commit'lenmemişse de PASS) ──
        r.append(check("FaceEmbedder model durumu (bilgi)") {
            let available = FaceEmbedder().isAvailable
            return (true, available ? "MobileFaceNet.mlmodelc YÜKLÜ — canlı % aktif" : "model yok — % gizli (graceful)")
        })

        let passed = r.filter { $0.passed }.count
        if passed == r.count {
            Log.info("Stage3 self-test: \(passed)/\(r.count) PASSED", category: .flow)
        } else {
            Log.error("Stage3 self-test: \(passed)/\(r.count) passed — \(r.count - passed) FAILED", category: .flow)
            for f in r where !f.passed {
                Log.error("Stage3 FAIL: \(f.name) — \(f.detail)", category: .flow)
            }
        }
        return r
    }

    // MARK: - Yardımcılar

    private static func signals(
        yaw: Float = 0, pitch: Float = 0, roll: Float = 0,
        leftEyeOpen: Float = 1, rightEyeOpen: Float = 1, smile: Float = 0,
        boundingBox: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    ) -> FaceSignals {
        FaceSignals(yaw: yaw, pitch: pitch, roll: roll,
                    leftEyeOpen: leftEyeOpen, rightEyeOpen: rightEyeOpen, smile: smile,
                    boundingBox: boundingBox, leftEye: nil, rightEye: nil)
    }

    private static func approx(_ a: Float, _ b: Float, tol: Float) -> Bool { abs(a - b) <= tol }

    private static func check(_ name: String, _ body: () throws -> (Bool, String)) -> SelfTestResult {
        do {
            let (passed, detail) = try body()
            return SelfTestResult(name: name, passed: passed, detail: detail)
        } catch {
            return SelfTestResult(name: name, passed: false, detail: "throw: \(error)")
        }
    }
}
