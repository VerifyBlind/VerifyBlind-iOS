import SwiftUI
import CoreImage
import CoreVideo
import Vision

/// Liveness orkestrasyonu — Android `LivenessActivity` portu.
///
/// Ön kamera + `FaceAnalyzer` ile challenge sırasını (≥5) yürütür, 30sn timer, jest ilerlemesi
/// (yanlış kafa-dönüşü sıfırlar; blink/smile yok sayılır), kare-yakalama best-frame mantığı
/// (match-iyileşmesi / kalite / ilk-kayıt) ve `MATCH_THRESHOLD=0.65`. Çıktı: hizalanmış 112×112
/// selfie JPEG + eşleşme sonucu. Chip (DG2) verilmezse %'siz çalışır (Android null-chip yolu).
///
/// İPLİK DİSİPLİNİ: TÜM logic durumu (index, skorlar, embedding) yalnız kamera VİDEO KUYRUĞUNDA
/// okunur/yazılır (`camera.runOnVideoQueue` + `analyzer.onFace`); `@Published` sunum güncellemeleri
/// daima ana kuyruğa marshalled edilir. Bu yüzden `@MainActor` KULLANILMAZ (video kuyruğu logic'i
/// ile çakışırdı).
final class LivenessViewModel: ObservableObject {

    static let matchThreshold: Float = 0.65

    enum Phase: Equatable {
        case preparing
        case running
        case success
        case failure(timeout: Bool)
    }

    // MARK: Sunum (yalnız ana kuyruk)
    @Published var phase: Phase = .preparing
    @Published var instruction = ""
    @Published var subInstruction = ""
    @Published var stepText = ""
    @Published var timerText = "30"
    @Published var liveScorePercent = 0
    @Published var showScore = false   // chipEmbedding != nil
    @Published var checkmark = false
    @Published var wrongMove = false
    @Published var qualityWarning: String?   // (b) ışık uyarısı — Android tvQualityWarning karşılığı
    @Published var debugEyeOpen = 0   // dev: canlı göz-açıklık % (blink kalibrasyonu)
    @Published var debugSmile = 0     // dev: canlı smile sinyali ×100 (smile kalibrasyonu)
    @Published private(set) var alignedSelfieJPEG: Data?
    @Published private(set) var selfiePreview: UIImage?
    @Published private(set) var chipPreview: UIImage?
    private(set) var finalMatchScore: Float = 0

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()
    private let embedder = FaceEmbedder()
    private let ciContext = CIContext()

    private let challengesInput: [LivenessAction]
    private let chipPhotoData: Data?
    private let isDemo: Bool

    // MARK: Logic durumu (yalnız video kuyruğu)
    private var challenges: [LivenessAction] = []
    private var index = 0
    private var chipEmbedding: [Float]?
    private var isIdentityVerified = false
    private var bestMatchScore: Float = 0
    private var bestSavedMatchScore: Float = -1
    private var bestSavedQualityScore: Float = -1
    private var lastActionTime: TimeInterval = 0
    private var lastCaptureTime: TimeInterval = 0
    private var selfieJPEG: Data?
    private let blinkDetector = BlinkDetector()
    private let smileDetector = SmileDetector()

    private var timer: Timer?
    private var startedAt: Date?

    init(challenges: [Int], chipPhotoData: Data?, isDemo: Bool = false) {
        self.challengesInput = challenges.map(LivenessAction.fromInt).filter { $0 != .none }
        self.chipPhotoData = chipPhotoData
        self.isDemo = isDemo
    }

    // MARK: - Yaşam döngüsü (ana kuyruk)

    func start() {
        showScore = chipPhotoData != nil
        if let data = chipPhotoData, let ui = UIImage(data: data) { chipPreview = ui }

        camera.onFrame = { [weak self] buffer, orientation in
            self?.updateQualityWarning(for: buffer)   // (b) ışık uyarısı — her kare (yüz olmasa da)
            self?.analyzer.process(buffer, orientation: orientation)
        }
        analyzer.onFace = { [weak self] frame in
            self?.handleFace(frame) // video kuyruğu
        }
        beginRun()
    }

    func stop() {
        invalidateTimer()
        camera.stop()
    }

    func retry() {
        beginRun()
    }

    private func beginRun() {
        camera.start() // idempotent (isRunning ile korumalı) — retry'de stop sonrası yeniden başlatır
        phase = .running
        liveScorePercent = 0
        checkmark = false
        wrongMove = false
        alignedSelfieJPEG = nil
        selfiePreview = nil
        startTimer()
        camera.runOnVideoQueue { [weak self] in
            guard let self else { return }
            self.resetLogicState()
            self.prepareChipEmbeddingIfNeeded()
            if self.isDemo {
                DispatchQueue.main.async { self.presentDemoStep(0) }
            } else {
                self.presentChallengeForIndex()
            }
        }
    }

    // MARK: - Video kuyruğu logic

    private func resetLogicState() {
        var list = challengesInput
        while list.count < 5 { list.append(.randomGesture()) }
        challenges = list
        index = 0
        bestMatchScore = 0
        bestSavedMatchScore = -1
        bestSavedQualityScore = -1
        isIdentityVerified = false
        selfieJPEG = nil
        lastActionTime = 0
        lastCaptureTime = 0
    }

    private func prepareChipEmbeddingIfNeeded() {
        guard chipEmbedding == nil, let data = chipPhotoData, let cg = UIImage(data: data)?.cgImage else { return }
        let eyes = Self.detectEyes(in: cg)
        if let aligned = FaceAligner.alignedImage(from: cg, leftEye: eyes.left, rightEye: eyes.right) {
            chipEmbedding = embedder.embedding(from: aligned)
        }
        let method = eyes.left != nil ? "ALIGNED" : "FALLBACK"
        Log.info("Liveness chip embedding (\(method)) size=\(chipEmbedding?.count ?? 0)", category: .liveness)
    }

    /// index'i (video kuyruğu) okur ve UI'yi ana kuyrukta sunar. index taşmışsa başarı değerlendir.
    private func presentChallengeForIndex() {
        blinkDetector.resetArmed(); smileDetector.reset() // yeni challenge → yarım kalan blink durumu sıfırla
        if index >= challenges.count {
            finalizeSuccessAttempt()
            return
        }
        let action = challenges[index]
        let step = "\(index + 1)/\(challenges.count)"
        DispatchQueue.main.async { [weak self] in
            self?.presentChallenge(action: action, step: step)
        }
    }

    private func handleFace(_ frame: FaceAnalyzer.Frame) {
        let quality = LivenessGestureDetector.qualityScore(frame.signals, imageSize: frame.imageSize)
        captureFrame(frame, quality: quality)
        processAction(frame.signals)
    }

    private func processAction(_ signals: FaceSignals) {
        guard !isDemo, index < challenges.count else { return }
        let now = Date().timeIntervalSince1970 * 1000

        // Canlı kalibrasyon göstergeleri (dev) — her karede.
        let eyeOpen = min(signals.leftEyeOpen, signals.rightEyeOpen)
        let eyePct = Int(eyeOpen * 100)
        let smilePct = Int(signals.smile * 100)
        DispatchQueue.main.async { [weak self] in
            self?.debugEyeOpen = eyePct
            self?.debugSmile = smilePct
        }

        let target = challenges[index]

        // Göreceli detektörleri HER karede besle (throttle'dan ÖNCE) → nötr baseline erken yakalanır.
        // Smile bug'ı: throttle (2s) bitene kadar besleme yoktu; kullanıcı "Gülümseyin"i görüp hemen
        // gülünce baseline yüksek başlıyor, ilk gülümseme "yükseliş" sayılmıyordu (ikincide oluyordu).
        let blinkFired = (target == .blink) ? blinkDetector.feed(eyeOpen) : false
        let smileFired = (target == .smile) ? smileDetector.feed(signals.smile) : false

        // İlerleme throttle'dan SONRA (önceki jestin yeni challenge'a sızmasını önler).
        guard now - lastActionTime >= 2000 else { return }

        // Blink: göreceli detektör (Vision gözü tam kapatmıyor) + statik fallback.
        if target == .blink {
            if blinkFired || LivenessGestureDetector.detect(signals) == .blink {
                advanceOnSuccess(now: now)
            }
            return
        }

        // Smile: göreceli detektör (Vision smile olasılığı yok) + statik fallback.
        if target == .smile {
            if smileFired || LivenessGestureDetector.detect(signals) == .smile {
                advanceOnSuccess(now: now)
            }
            return
        }

        // left/right: tek-kare detect.
        guard let detected = LivenessGestureDetector.detect(signals) else { return }
        if detected == target {
            advanceOnSuccess(now: now)
        } else if target == .faceLeft || target == .faceRight {
            resetOnWrong(now: now) // yanlış kafa dönüşü → baştan (Android STRICT)
        }
    }

    private func advanceOnSuccess(now: TimeInterval) {
        lastActionTime = now
        index += 1
        blinkDetector.resetArmed(); smileDetector.reset()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkmark = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.camera.runOnVideoQueue { self.presentChallengeForIndex() }
            }
        }
    }

    private func resetOnWrong(now: TimeInterval) {
        lastActionTime = now
        index = 0
        blinkDetector.resetArmed(); smileDetector.reset()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wrongMove = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.wrongMove = false
                self.camera.runOnVideoQueue { self.presentChallengeForIndex() }
            }
        }
    }

    /// Best-frame yakalama (Android captureFrame). 400ms throttle.
    private func captureFrame(_ frame: FaceAnalyzer.Frame, quality: Float) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastCaptureTime >= 400 else { return }
        lastCaptureTime = now

        guard let fullCG = cgImage(from: frame.pixelBuffer) else { return }
        let box = frame.signals.boundingBox
        let margin = box.width * 0.4
        let left = max(0, box.minX - margin)
        let top = max(0, box.minY - margin)
        let right = min(frame.imageSize.width, box.maxX + margin)
        let bottom = min(frame.imageSize.height, box.maxY + margin)
        let w = right - left, h = bottom - top
        guard w > 50, h > 50, let crop = fullCG.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else { return }

        let leftEyeInCrop = frame.signals.leftEye.map { CGPoint(x: $0.x - left, y: $0.y - top) }
        let rightEyeInCrop = frame.signals.rightEye.map { CGPoint(x: $0.x - left, y: $0.y - top) }
        guard let aligned = FaceAligner.alignedImage(from: crop, leftEye: leftEyeInCrop, rightEye: rightEyeInCrop) else { return }

        var currentMatch: Float = 0
        if let chipEmbedding, let selfieEmb = embedder.embedding(from: aligned) {
            currentMatch = FaceEmbedder.cosineSimilarity(chipEmbedding, selfieEmb)
        }

        var shouldSave = false
        if chipEmbedding != nil {
            if currentMatch > bestSavedMatchScore + 0.005 {
                shouldSave = true
            } else if abs(currentMatch - bestSavedMatchScore) < 0.005, quality > bestSavedQualityScore + 5 {
                shouldSave = true
            } else if selfieJPEG == nil {
                shouldSave = true
            }
        } else if quality > bestSavedQualityScore + 5 || selfieJPEG == nil {
            shouldSave = true
        }

        if shouldSave {
            selfieJPEG = UIImage(cgImage: aligned).jpegData(compressionQuality: 0.95)
            bestSavedMatchScore = currentMatch
            bestSavedQualityScore = quality
            if currentMatch > bestMatchScore { bestMatchScore = currentMatch }
            if currentMatch > Self.matchThreshold { isIdentityVerified = true }
        }

        let scorePercent = Int(bestMatchScore * 100)
        let preview = UIImage(cgImage: aligned)
        let jpeg = selfieJPEG
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveScorePercent = scorePercent
            self.selfiePreview = preview
            if let jpeg { self.alignedSelfieJPEG = jpeg }
        }
    }

    /// Başarı değerlendirmesi (video kuyruğu) — tüm logic-state burada okunur, sonuç main'e taşınır.
    private func finalizeSuccessAttempt() {
        let hasSelfie = selfieJPEG != nil
        let verified = isIdentityVerified
        let hasChip = chipEmbedding != nil
        let score = bestMatchScore
        let jpeg = selfieJPEG

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidateTimer()
            self.camera.stop()
            self.finalMatchScore = score
            if !hasSelfie {
                self.phase = .failure(timeout: false) // selfie yok
                return
            }
            if hasChip && !verified {
                self.phase = .failure(timeout: false)
                return
            }
            if let jpeg { self.alignedSelfieJPEG = jpeg }
            Log.info("Liveness başarı: score=\(Int(score * 100))% verified=\(verified)", category: .liveness)
            self.phase = .success
        }
    }

    private func finalizeTimeout() {
        let score = bestMatchScore
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidateTimer()
            self.camera.stop()
            self.finalMatchScore = score
            Log.warning("Liveness timeout — bestScore=\(Int(score * 100))%", category: .liveness)
            self.phase = .failure(timeout: true)
        }
    }

    // MARK: - Sunum (ana kuyruk)

    private func presentChallenge(action: LivenessAction, step: String) {
        stepText = step
        checkmark = false
        wrongMove = false
        switch action {
        case .faceLeft:  instruction = NSLocalizedString("liveness_face_left", comment: "")
        case .faceRight: instruction = NSLocalizedString("liveness_face_right", comment: "")
        case .blink:     instruction = NSLocalizedString("liveness_face_blink", comment: "")
        case .smile:     instruction = NSLocalizedString("liveness_face_smile", comment: "")
        case .none:      instruction = "—"
        }
        subInstruction = "Hareketi yapın"
    }

    // Demo: gerçek jest/selfie gerekmez — her adımı 1sn sonra otomatik onayla (Android demo).
    private func presentDemoStep(_ step: Int) {
        guard phase == .running else { return }
        let demoList = paddedDemoChallenges()
        if step >= demoList.count {
            invalidateTimer()
            camera.stop()
            // Demo selfie gerektirmez (runDemo selfieData'yı kullanmaz). Ama telefon masadaysa/yüz
            // yoksa captureFrame hiç çalışmaz → alignedSelfieJPEG nil kalır ve View'ın onSuccess
            // koşulu (`let jpeg = alignedSelfieJPEG`) sağlanmaz → akış .processing'e geçemez, ekran
            // durmuş kamerada kilitlenir. Yüz yakalanmadıysa boş placeholder ver ki demo tıkanmasın.
            if alignedSelfieJPEG == nil { alignedSelfieJPEG = Data() }
            phase = .success
            return
        }
        presentChallenge(action: demoList[step], step: "\(step + 1)/\(demoList.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .running else { return }
            self.checkmark = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.presentDemoStep(step + 1) }
        }
    }

    private func paddedDemoChallenges() -> [LivenessAction] {
        var list = challengesInput
        while list.count < 5 { list.append(.randomGesture()) }
        return list
    }

    // MARK: - Timer (ana kuyruk)

    private func startTimer() {
        startedAt = Date()
        timerText = "30"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let remaining = max(0, 30 - Int(Date().timeIntervalSince(startedAt)))
            self.timerText = "\(remaining)"
            if remaining <= 0 {
                self.timer?.invalidate()
                self.camera.runOnVideoQueue { self.finalizeTimeout() }
            }
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Görüntü yardımcıları

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - (b) Ortam kalitesi (ışık) — Android LivenessAnalyzer.averageLuma karşılığı

    /// Her karede ortalama parlaklığı ölçer ve karanlık/aşırı-parlak uyarısını (ana kuyrukta) günceller.
    /// Video kuyruğunda çağrılır (Android onFrameLuma ile aynı disiplin).
    private func updateQualityWarning(for pixelBuffer: CVPixelBuffer) {
        let luma = Self.averageLuma(pixelBuffer)
        let warning: String?
        if luma < 55 {
            warning = NSLocalizedString("liveness_quality_dark", comment: "")
        } else if luma > 235 {
            warning = NSLocalizedString("liveness_quality_bright", comment: "")
        } else {
            warning = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.qualityWarning != warning else { return }
            self.qualityWarning = warning
        }
    }

    /// BGRA pixel buffer'dan ~2048 örnekle ortalama parlaklık (0..255). Hatada 128 (nötr).
    /// iOS kamerası kCVPixelFormatType_32BGRA verir → Y düzlemi yok, luma BGRA'dan türetilir.
    static func averageLuma(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 128 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return 128 }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let total = width * height
        let step = max(1, total / 2048)
        var sum = 0
        var count = 0
        var i = 0
        while i < total {
            let x = i % width
            let y = i / width
            let off = y * bytesPerRow + x * 4   // BGRA
            let b = Int(ptr[off]); let g = Int(ptr[off + 1]); let r = Int(ptr[off + 2])
            sum += (r * 77 + g * 150 + b * 29) >> 8   // ~Rec.601 luma
            count += 1
            i += step
        }
        return count > 0 ? Float(sum) / Float(count) : 128
    }

    /// Tek-atış yüz/göz tespiti (chip fotoğrafı) — top-left piksel göz merkezleri.
    static func detectEyes(in image: CGImage) -> (left: CGPoint?, right: CGPoint?) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let face = request.results?.first else { return (nil, nil) }
        let size = CGSize(width: image.width, height: image.height)

        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = region?.pointsInImage(imageSize: size), !pts.isEmpty else { return nil }
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(pts.count), y: size.height - sy / CGFloat(pts.count))
        }
        return (center(face.landmarks?.leftEye), center(face.landmarks?.rightEye))
    }
}
