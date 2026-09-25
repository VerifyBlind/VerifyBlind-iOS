import SwiftUI
import CoreImage
import CoreVideo
import Vision

/// Liveness orkestrasyonu — Android `LivenessActivity` portu.
///
/// Ön kamera + `FaceAnalyzer` ile sunucunun OLAY DİZİSİNİ (`EventSequencer`) yürütür: her hareketten
/// önce nötr kare, hareket anında olay karesi; kareler yüzün çevresinden kırpılıp kayıt yüküne
/// `ChoreographyProof` olarak girer ve enclave HER karede kimliği doğrular. Yanında kare-yakalama
/// best-frame mantığı (match-iyileşmesi / kalite / ilk-kayıt) ve `MATCH_THRESHOLD=0.65`. Çıktı:
/// hizalanmış 112×112 selfie + eşleşme sonucu + olay kanıtı. Chip (DG2) verilmezse %'siz çalışır.
///
/// 🔴 Mesafe ve kafa çevirme YOK (2026-09-25): tek rahat mesafede göz kırpma, gülümseme, ağız açma,
/// çift kırpma. Oval çerçeve de kalktı (bkz. `FaceFrameView`).
///
/// İPLİK DİSİPLİNİ: TÜM logic durumu (dizi, skorlar, embedding) yalnız kamera VİDEO KUYRUĞUNDA
/// okunur/yazılır (`analyzer.onFace`/`onNoFace`); `@Published` sunum güncellemeleri daima ana
/// kuyruğa marshalled edilir. Bu yüzden `@MainActor` KULLANILMAZ.
///
/// 🔴 `camera.runOnVideoQueue` KULLANILMAZ. Kareler akarken kuyruğa sonradan atılan iş saniyelerce
/// bekletiliyor: 2026-09-25'te kılavuzdaki "Başla"dan sonra koşuyu başlatacak iş 22 sn bekledi ve
/// ancak kullanıcı vazgeçip kamera durunca çalıştı — ekran boş talimatla donmuş göründü (2026-08-25'te
/// aynı sıçrama 40 sn beklemişti). Başlatma artık bir bayrakla isteniyor ve kare döngüsünün KENDİSİ
/// bir sonraki karede başlatıyor (`takeStartRequest`).
final class LivenessViewModel: ObservableObject {

    static let matchThreshold: Float = 0.65

    /// Kalan süre bu oranın altına inince çizgi kehribara döner ve tek bir sessiz dokunuş gelir.
    static let lowTimeFraction = 0.27

    /// Kare akışı bu kadar süre durursa (kamera takıldı) akış biter. Dizinin kendi saati kare
    /// döngüsünde işliyor; kare hiç gelmezse o saat de durur ve kullanıcı donmuş ekranda kalırdı.
    static let stallTimeout: TimeInterval = 6

    enum FailureReason: Equatable {
        /// Hareket için ayrılan süre doldu. Kullanıcı komutu anlamadı ya da yapamadı.
        case gestureTimeout
        /// Yüz yerleştirilip gevşetilemedi (çerçeve, ışık).
        case settleTimeout
        /// Kare akışı durdu (bekçi).
        case sessionTimeout
        case tooManyErrors
        /// Yüz adım adım kayboldu.
        case tooManyResets
        case noSelfie
        case matchFailed
        /// Sunucu olay dizisi göndermedi — sürüm uyuşmazlığı.
        case missingSequence

        /// Huninin sabit sebep kümesindeki karşılığı (Android `EventCollector.Failure.flowReason`).
        var flowReason: String {
            switch self {
            case .gestureTimeout, .settleTimeout: return "timeout_gesture"
            case .sessionTimeout: return "timeout_session"
            case .tooManyErrors, .tooManyResets: return "too_many_errors"
            case .noSelfie: return "no_selfie"
            case .matchFailed: return "match_failed"
            case .missingSequence: return "missing_sequence"
            }
        }

        var isTimeout: Bool { self == .gestureTimeout || self == .sessionTimeout }
    }

    enum Phase: Equatable {
        case preparing
        /// Başlamadan önceki kılavuz — "Başla"ya basılınca koşu başlar.
        case guide
        case running
        case success
        case failure(FailureReason)
    }

    // MARK: Sunum (yalnız ana kuyruk)
    @Published var phase: Phase = .preparing
    @Published var instruction = ""
    @Published var subInstruction = ""
    @Published var stepText = ""
    /// Aktif adımın kalan süre oranı (1 → tam, 0 → doldu). Rakam değil, çerçevede eriyen çizgi.
    @Published var timeProgress: Double = 1
    /// Yüz yerinde ve hazır → çerçeve yeşil; değilse kırmızı.
    @Published var frameAligned = false
    @Published var liveScorePercent = 0
    @Published var showScore = false   // chipEmbedding != nil
    @Published var checkmark = false
    /// Tek seferlik uyarı: yanlış hareket ya da adımın yeniden başlaması. ~1.5 sn görünür.
    @Published var notice: String?
    @Published var qualityWarning: String?   // ışık/netlik/yüz uyarısı — Android tvQualityWarning karşılığı
    @Published private(set) var alignedSelfieJPEG: Data?

    /// Teşhis için dışarı verilebilecek son kare — başarıda da BAŞARISIZLIKTA da aynı kare:
    /// gönderilebilseydi sunucunun göreceği kare buydu. Cihazdan KENDİLİĞİNDEN çıkmaz: kullanıcı
    /// geri bildirim kutusunda açıkça işaretlerse e-postaya ek olur. Demo yer tutucusu teşhis değildir.
    var diagnosticJPEG: Data? {
        guard let data = alignedSelfieJPEG, !data.isEmpty else { return nil }
        return data
    }
    @Published private(set) var antiSpoofCropJPEG: Data?

    /// Çip fotoğrafının MODELE GİREN hâli (hizalanmış 112×112 PNG). Buradan hiçbir yere GİTMEZ —
    /// yalnız geri bildirim kutusunda kullanıcı AYRI bir anahtarı açarsa e-postaya ek olur.
    @Published private(set) var alignedChipPNG: Data?

    /// Son denemenin skaler ölçüleri — geri bildirim e-postasının gövdesine eklenir. Hepsi SKALER:
    /// biyometrik veri değil, görüntü değil.
    @Published private(set) var diagnosticsSummary: String = ""
    @Published private(set) var selfiePreview: UIImage?
    @Published private(set) var chipPreview: UIImage?
    private(set) var finalMatchScore: Float = 0

    /// Başarıda kayıt yüküne giren olay kanıtı (ana kuyrukta okunur).
    private(set) var choreographyProof: ChoreographyProof?

    /// Kılavuzdaki "Sizden sırayla N hareket istenecek" için.
    var eventCountForGuide: Int { events.count }

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()
    private let embedder = FaceEmbedder()
    private var ciContext: CIContext { FaceAnalyzer.sharedCIContext }   // tek paylaşılan context

    private let events: [EventSequencer.Event]
    private let chipPhotoData: Data?
    private let isDemo: Bool

    // MARK: Logic durumu (yalnız video kuyruğu)
    private var sequencer: EventSequencer?
    private var chipEmbedding: [Float]?
    /// Çip fotoğrafı VERİLDİ ama görüntü çözülemedi (ör. JPEG2000 DG2). "Çip yok" durumundan
    /// ayırt edilmeli: orada eşleştirme beklenmez, burada eşleştirme YAPILAMADI ve sessizce
    /// geçilirse doğrulanmamış kayıt oluşur (Android `chipDecodeFailed` paritesi).
    private var chipDecodeFailed = false
    private var isIdentityVerified = false
    private var bestMatchScore: Float = 0
    private var bestSavedMatchScore: Float = -1
    private var bestSavedQualityScore: Float = -1
    private var lastCaptureTime: TimeInterval = 0
    private var selfieJPEG: Data?
    private var antiSpoofCropJPEGLogic: Data?
    private var lastLuma: Float = -1   // en son ölçülen ortalama parlaklık (0-255)
    /// Sunucuya GİDEN kareye ait kalite ölçüleri — "neden sahte sanıldı" sorusunu ancak bu
    /// skalerler yanıtlayabilir: ışık, netlik, poz, yüzün kadrajdaki payı.
    private var savedFrameMetrics: String?
    private var lumaWarning: String?   // ışık uyarısı (her kare — video kuyruğu)
    private var blurWarning: String?   // netlik uyarısı (best-frame yakalamada — video kuyruğu)
    private let feedback = LivenessFeedback()
    /// Yüz izleme sürekliliği — son yüz görülme anı (ms, epoch).
    private var lastFaceTime: TimeInterval = 0
    /// Son sunum — yalnız DEĞİŞİNCE ana kuyruğa taşınır (her karede @Published yazmamak için).
    private var lastPresentation: Presentation?
    private var lastPublishedTime: Double = 1
    /// "Süre azalıyor" dokunuşu adım başına bir kez.
    private var nudgedStep = -1
    /// Teşhis özeti için ilerleme — TEK KELİMELİK sayılar. Bekçi ana kuyruktan özet ürettiğinde
    /// dizinin kendisine (diziler taşıyan bir yapı) dokunmasın: eşzamanlı kopyalama çökebilir.
    private var progressSteps = 0
    private var progressWrong = 0

    /// Koşu başladıktan sonra "yüz yok" demeden önce beklenen süre — kamera ısınsın, kullanıcı
    /// telefonu yerleştirsin diye. Bu süre içinde uyarı verirsek her koşu bir azarla açılır.
    static let noFaceGraceMs: TimeInterval = 2000
    /// Yüzün kaç ms kayıp kalması uyarıyı hak eder.
    static let noFaceWarnMs: TimeInterval = 1500
    /// Koşunun (video kuyruğunda) başladığı an — "yüz yok" uyarısının gecikmesi buradan ölçülür.
    private var runStartedAtMs: TimeInterval = 0
    /// "Yüzünüz çerçevede değil" uyarısı (video kuyruğu).
    private var faceMissingWarning: String?

    /// Koşu başlatma isteği — ana kuyrukta yazılır, kare döngüsünde (video kuyruğu) tüketilir.
    /// Kilit, iki kuyruğun aynı Bool'a eşzamanlı dokunması için; iş kuyruğa ATILMAZ (bkz. sınıf notu).
    private let startLock = NSLock()
    private var startRequested = false

    /// Ana kuyruktaki bekçi — kare akışının durup durmadığını izler.
    private var watchdog: Timer?
    /// Son işlenen karenin anı (ms). Video kuyruğunda yazılır, bekçi okur (tek kelime).
    private var lastFrameAtMs: TimeInterval = 0
    private var sessionStartedAt: Date?

    /// Akışın huni anahtarı — hareket olayları koşu SIRASINDA doğuyor.
    private let flowNonce: String?

    /// Canlı benzerlik akışı — canlılık sürerken enclave'e kare gönderir (Android
    /// `LivenessActivity.streamer` paritesi). Ekrandaki 0.65 göstergesi bundan ETKİLENMEZ;
    /// enclave onayı yalnızca İKİNCİ bir submit yolu açar. nil = streaming yok.
    private let streamer: SimilarityStreamer?

    /// Kaydedilen en iyi karenin ölçüleri — submit'te **1. adayın** ölçüm satırı olur.
    private var bestFrameMetrics: DeviceFrameMetrics?

    /// Enclave'in onayladığı kare — submit'te **2. aday**. Yalnız 1. adaydan FARKLIYSA gönderilir.
    var enclaveApprovedSelfie: Data? { streamer?.approvedSelfie }
    var enclaveApprovedCrop: Data? { streamer?.approvedCrop }
    var enclaveApprovedMetrics: DeviceFrameMetrics? { streamer?.approvedMetrics }
    /// 1. adayın ölçüleri — RegisterViewModel ölçüm satırını bununla yazar.
    var bestCandidateMetrics: DeviceFrameMetrics? { bestFrameMetrics }
    /// Adayların KAYNAK KARE numaraları — final satırı ile onu üreten streaming satırını birleştirir.
    var bestSourceSeq: Int? { streamer?.lastSentSeq }
    var approvedSourceSeq: Int? { streamer?.approvedSeq }

    /// Demo dizisi — gerçek sunucu dizisi yoksa (Android `DEMO_EVENTS` paritesi).
    static let demoEvents: [Int] = [1, 2, 3]

    private struct Presentation: Equatable {
        var instruction: String
        var sub: String
        var step: String
        var aligned: Bool
        var checkmark: Bool
    }

    init(events: [Int], chipPhotoData: Data?, isDemo: Bool = false, flowNonce: String? = nil,
         flowId: String? = nil, enclavePubKey: String? = nil, dg2Raw: Data? = nil) {
        // Bilinmeyen bir kod gelirse (ileri sürüm sunucu) dizi KULLANILMAZ — yarım anlaşılmış bir
        // diziyi yürütmek enclave'de "yapı bozuk" reddi demek.
        let parsed = events.compactMap(EventSequencer.Event.init(rawValue:))
        let usable = !parsed.isEmpty && parsed.count == events.count
        if usable {
            self.events = parsed
        } else if isDemo {
            self.events = Self.demoEvents.compactMap(EventSequencer.Event.init(rawValue:))
        } else {
            self.events = []
        }
        self.chipPhotoData = chipPhotoData
        self.isDemo = isDemo
        self.flowNonce = flowNonce

        // Canlı benzerlik akışı: yalnız gerçek akışta ve yalnız üç girdi de varken.
        // ⚠️ HAM DG2 gönderilir, chipPhotoData DEĞİL: enclave benzerlik referansını
        // SOD-doğrulanmış ham DG2'den çıkarır (register ile AYNI boru hattı).
        if !isDemo, let flowId, let enclavePubKey, let dg2Raw, !dg2Raw.isEmpty {
            let st = SimilarityStreamer(flowId: flowId, enclavePubKey: enclavePubKey)
            st.prepare(dg2Raw: dg2Raw)
            self.streamer = st
        } else {
            self.streamer = nil
        }
    }

    // MARK: - Yaşam döngüsü (ana kuyruk)

    func start() {
        showScore = chipPhotoData != nil
        if let data = chipPhotoData, let ui = UIImage(data: data) { chipPreview = ui }

        camera.onFrame = { [weak self] buffer, _ in
            self?.updateQualityWarning(for: buffer)   // ışık uyarısı — her kare (yüz olmasa da)
        }
        // ML Kit `VisionImage`'ı CVPixelBuffer kabul etmiyor → yüz analizi ayrı kanaldan besleniyor.
        camera.onSampleBuffer = { [weak self] sample, orientation in
            self?.analyzer.process(sample, orientation: orientation)
        }
        // Dudak konturu yalnız ağız açma adımında: ikinci dedektör kare hızını düşürür.
        analyzer.contourWanted = { [weak self] in self?.sequencer?.wantsContour == true }
        // Yüz bulunamayan karelerde de dizinin saati işlemeli: yüz kaybı adımı yeniden başlatır.
        analyzer.onNoFace = { [weak self] in self?.handleNoFace() }
        analyzer.onFace = { [weak self] frame in
            self?.handleFace(frame) // video kuyruğu
        }

        guard isDemo || !events.isEmpty else {
            // Sunucu dizi göndermedi: kanıtsız kayıt enclave'de eski sürüm gibi kapısız geçerdi —
            // yeni istemcinin bu yola düşmesi bir sürüm uyuşmazlığıdır, sessizce kabul edilmez.
            Log.error("Olay dizisi yok — sunucu göndermedi ya da anlaşılamadı; akış başlatılmıyor",
                      category: .liveness)
            phase = .failure(.missingSequence)
            return
        }
        // Kamera kılavuz ekrandayken ısınır; kareler dizi başlayana dek işlenmez.
        camera.start()
        phase = .guide
    }

    /// Kılavuzdaki "Başla".
    func beginAfterGuide() {
        guard phase == .guide else { return }
        beginRun()
    }

    func stop() {
        invalidateWatchdog()
        camera.stop()
        feedback.deactivate()
        // Akış nasıl biterse bitsin gömme vektörü bırakılır. Başarı ve hata yollarında zaten
        // çağrıldı; burası SESSİZ çıkışı yakalar. Streamer ilk sebebi tuttuğu için buradaki
        // "abandoned" ancak hiçbir sebep bildirilmediyse kazanır.
        streamer?.release(outcome: "abandoned")
    }

    func retry() {
        Log.info("Liveness: 'Tekrar Dene' → koşu yeniden başlatılıyor", category: .liveness)
        if case .failure(.missingSequence) = phase { return }
        beginRun()
    }

    private func beginRun() {
        feedback.activate()   // sessiz moddayken de duyulmalı (Android medya akışıyla parite)
        camera.start() // idempotent (isRunning ile korumalı) — retry'de stop sonrası yeniden başlatır
        phase = .running
        liveScorePercent = 0
        checkmark = false
        notice = nil
        timeProgress = 1
        frameAligned = false
        alignedSelfieJPEG = nil
        selfiePreview = nil
        choreographyProof = nil
        sessionStartedAt = Date()
        lastFrameAtMs = Date().timeIntervalSince1970 * 1000
        startWatchdog()
        // Kare döngüsü bir sonraki karede başlatır. Kare hiç gelmezse bekçi `stallTimeout` sonra
        // akışı bitirir — kullanıcı boş ekranda kalmaz.
        startLock.lock()
        startRequested = true
        startLock.unlock()
    }

    /// İstenmiş bir başlatma varsa tüketir (video kuyruğu, her karede).
    private func takeStartRequest() -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        let requested = startRequested
        startRequested = false
        return requested
    }

    /// Koşuyu başlatır — yalnız kare döngüsünden (video kuyruğu).
    private func startLogic() {
        resetLogicState()
        prepareChipEmbeddingIfNeeded()
        if isDemo {
            DispatchQueue.main.async { [weak self] in self?.presentDemoStep(0) }
        } else {
            var seq = EventSequencer(events: events)
            seq.start(now: Self.nowMs)
            sequencer = seq
            present(seq)
        }
    }

    // MARK: - Video kuyruğu logic

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    private func resetLogicState() {
        sequencer = nil
        bestMatchScore = 0
        bestSavedMatchScore = -1
        bestSavedQualityScore = -1
        isIdentityVerified = false
        selfieJPEG = nil
        antiSpoofCropJPEGLogic = nil
        bestFrameMetrics = nil
        lastCaptureTime = 0
        savedFrameMetrics = nil
        lastFaceTime = 0
        lastPresentation = nil
        lastPublishedTime = 1
        nudgedStep = -1
        progressSteps = 0
        progressWrong = 0
        runStartedAtMs = Self.nowMs
        faceMissingWarning = nil
        // `chipEmbedding` bilerek korunur (bir kez üretilir, koşular arası yeniden kullanılır);
        // çözülememe bayrağı da onunla aynı ömre sahip olmalı ki "Tekrar Dene" kapıyı açmasın.
        chipDecodeFailed = chipDecodeFailed && chipEmbedding == nil
        analyzer.resetDiagnostics()
    }

    private func prepareChipEmbeddingIfNeeded() {
        guard chipEmbedding == nil, let data = chipPhotoData else { return }
        guard let cg = UIImage(data: data)?.cgImage else {
            // Çip fotoğrafı VERİLDİ ama çözülemedi. Bayrak şart: başarı kapısı bunu "çip yok"
            // sanıp sessizce geçiyordu (parite denetimi 2026-09-03, O-5).
            chipDecodeFailed = true
            Log.error("Çip fotoğrafı çözülemedi — cihazda yüz eşleştirmesi yapılamayacak",
                      category: .liveness)
            return
        }
        let eyes = Self.detectEyes(in: cg)
        if let aligned = FaceAligner.alignedImage(from: cg, leftEye: eyes.left, rightEye: eyes.right) {
            chipEmbedding = embedder.embedding(from: aligned)
            // AYNI hizalanmış kareyi teşhis için de saklıyoruz — eşleştirme yolu değişmez.
            let png = UIImage(cgImage: aligned).pngData()
            DispatchQueue.main.async { [weak self] in self?.alignedChipPNG = png }
        }
        let method = eyes.left != nil ? "ALIGNED" : "FALLBACK"
        Log.info("Liveness chip embedding (\(method)) size=\(chipEmbedding?.count ?? 0)", category: .liveness)
    }

    private func handleFace(_ frame: FaceAnalyzer.Frame) {
        if takeStartRequest() { startLogic() }
        let now = Self.nowMs
        lastFrameAtMs = now
        lastFaceTime = now
        let quality = LivenessGestureDetector.qualityScore(frame.signals, imageSize: frame.imageSize)

        if isDemo {
            captureFrame(frame, quality: quality, fullCG: nil)
            return
        }
        // Kılavuz ekrandayken ya da dizi bittiyse kareler dizinin işi değil.
        guard var seq = sequencer, seq.isActive else { return }

        // Tam kare bir kez üretilir: hem olay kırpması hem selfie adayı aynı kareyi kullanabilir.
        var fullCG: CGImage?
        let box = frame.signals.boundingBox
        var signals = seq.offer(frame.signals, frameSize: frame.imageSize, now: now) {
            if fullCG == nil {
                fullCG = analyzer.timing.measure("tamKare", { cgImage(from: frame.pixelBuffer) })
            }
            guard let cg = fullCG else { return nil }
            return analyzer.timing.measure("olayKırpma", { Self.faceCropJPEG(cg, box: box) })
        }
        signals += seq.tick(now: now)
        sequencer = seq

        // 🔴 Olay beklenirken selfie adayı (tam kare + hizalama + gömme) ERTELENİR: kare hızı
        // düşerse 100-150 ms'lik bir kırpma iki kare arasında kalır (Android'de sahada yaşandı).
        if !seq.quietPhase && seq.isActive {
            captureFrame(frame, quality: quality, fullCG: fullCG)
        }
        handle(signals, seq)
    }

    private func handleNoFace() {
        if takeStartRequest() { startLogic() }
        lastFrameAtMs = Self.nowMs
        guard var seq = sequencer, seq.isActive else { return }
        let signals = seq.tick(now: Self.nowMs)
        sequencer = seq
        handle(signals, seq)
    }

    /// Dizinin tek seferlik bildirimlerini işler ve sunumu günceller (video kuyruğu).
    private func handle(_ signals: [EventSequencer.Signal], _ seq: EventSequencer) {
        progressSteps = seq.completedSteps
        progressWrong = seq.wrongEvents
        for signal in signals {
            switch signal {
            case .stepDone:
                feedback.play(.stepOk)
            case .wrong(let event):
                feedback.play(.wrong)
                let did = L.t(event == .mouthOpen ? "liveness_did_mouth_open" : "liveness_did_smile")
                showNotice(L.t("liveness_wrong_move_detail", did))
            case .stepReset:
                feedback.play(.wrong)
                showNotice(L.t("liveness_ev_reset_face"))
            case .resolved(let event, let durationMs, let wrongCount, let timedOut):
                reportEvent(event, durationMs: durationMs, wrongCount: wrongCount, timedOut: timedOut)
            case .failed(let failure):
                // İz kaydı breadcrumb olarak kalır (olay değil → kota yemez, mesajı şişirmez) ve
                // hemen ardından `finalizeFailure`'ın yazdığı uyarıya iliştirilir.
                Log.info("Olay dizisi başarısız: \(failure) — iz: \(seq.trace)", category: .liveness)
                let reason: FailureReason
                switch failure {
                case .settleTimeout: reason = .settleTimeout
                case .eventTimeout: reason = .gestureTimeout
                case .tooManyWrong: reason = .tooManyErrors
                case .tooManyResets: reason = .tooManyResets
                }
                finalizeFailure(reason)
                return
            case .completed:
                choreographyProofLogic = Self.makeProof(seq, elapsedMs: Int(Self.nowMs - runStartedAtMs))
                finalizeSuccessAttempt()
                return
            }
        }
        present(seq)
    }

    /// Başarıda video kuyruğunda kurulur, `finalizeSuccessAttempt` ana kuyruğa taşır.
    private var choreographyProofLogic: ChoreographyProof?

    /// Kanıt: adım başına nötr + olay kareleri, iz kaydı ve sayaçlar.
    static func makeProof(_ seq: EventSequencer, elapsedMs: Int) -> ChoreographyProof {
        let steps = seq.steps.map { step in
            ChoreographyProofStep(
                neutral: step.neutral.map { [$0.base64EncodedString()] } ?? [],
                event: step.events.map { $0.base64EncodedString() },
                attempts: step.wrong + 1)
        }
        return ChoreographyProof(steps: steps, elapsedMs: elapsedMs, resets: seq.resets,
                                 wrongEvents: seq.wrongEvents, trackingChanges: nil, trace: seq.trace)
    }

    /// Dizinin durumunu ekrana çevirir; yalnız DEĞİŞENİ ana kuyruğa taşır.
    private func present(_ seq: EventSequencer) {
        let step = min(seq.completedSteps, max(seq.events.count - 1, 0))
        let stepLabel = seq.events.isEmpty ? "" : "\(step + 1)/\(seq.events.count)"
        var p = Presentation(instruction: "", sub: "", step: stepLabel, aligned: false, checkmark: false)
        switch seq.phase {
        case .settle:
            let placed = seq.framing == .ok
            p.aligned = placed && !seq.needsRelax
            switch seq.framing {
            case .tooSmall: p.instruction = L.t("liveness_ev_closer")
            case .tooLarge: p.instruction = L.t("liveness_ev_farther")
            case .offFrame: p.instruction = L.t("liveness_ev_place")
            case .ok: p.instruction = L.t(seq.needsRelax ? "liveness_face_smile_relax" : "liveness_ev_hold")
            }
            p.sub = L.t("liveness_ev_hold_hint")
        case .event:
            p.aligned = true
            if let event = seq.currentEvent {
                p.instruction = seq.needsRelax ? L.t("liveness_face_smile_relax") : Self.eventText(event)
                p.sub = seq.needsRelax ? L.t("liveness_ev_relax_hint")
                    : seq.eventCount == 1 ? L.t("liveness_ev_again") : Self.eventHint(event)
            }
        case .afterEvent:
            p.aligned = true
            p.checkmark = true
        case .done:
            return
        }

        if p != lastPresentation {
            lastPresentation = p
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .running else { return }
                self.instruction = p.instruction
                self.subInstruction = p.sub
                self.stepText = p.step
                self.frameAligned = p.aligned
                self.checkmark = p.checkmark
            }
        }

        // Kalan süre: yalnız belirgin değişimde yayınla; azalınca adım başına tek dokunuş.
        let left = seq.timeLeft
        if abs(left - lastPublishedTime) >= 0.01 || (left >= 1 && lastPublishedTime < 1) {
            lastPublishedTime = left
            DispatchQueue.main.async { [weak self] in self?.timeProgress = left }
        }
        if left <= Self.lowTimeFraction && nudgedStep != seq.completedSteps {
            nudgedStep = seq.completedSteps
            feedback.play(.nudge)
        }
    }

    private func showNotice(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notice = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.notice == text { self?.notice = nil }
            }
        }
    }

    static func eventText(_ event: EventSequencer.Event) -> String {
        switch event {
        case .blink: return L.t("liveness_face_blink")
        case .smile: return L.t("liveness_face_smile")
        case .mouthOpen: return L.t("liveness_face_mouth_open")
        case .doubleBlink: return L.t("liveness_face_double_blink")
        }
    }

    /// Hareketin NASIL yapılacağı — komutun altında, komutla aynı anda.
    static func eventHint(_ event: EventSequencer.Event) -> String {
        switch event {
        case .blink: return L.t("liveness_ev_hint_blink")
        case .smile: return L.t("liveness_ev_hint_smile")
        case .mouthOpen: return L.t("liveness_ev_hint_mouth_open")
        case .doubleBlink: return L.t("liveness_ev_hint_double_blink")
        }
    }

    /// Olay karesi: yüzün çevresinden kare kırpma (`FaceCrop`), uzun kenar en fazla 480, JPEG.
    static let eventOutputEdge = 480

    static func faceCropJPEG(_ cg: CGImage, box: CGRect) -> Data? {
        let rect = FaceCrop.squareAround(box, width: cg.width, height: cg.height)
        guard let cut = cg.cropping(to: rect) else { return nil }
        let side = min(eventOutputEdge, Int(rect.width))
        guard side > 0,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out).jpegData(compressionQuality: 0.88)
    }

    /// Best-frame yakalama (Android captureFrame). 400ms throttle.
    private func captureFrame(_ frame: FaceAnalyzer.Frame, quality: Float, fullCG preparedCG: CGImage?) {
        let now = Self.nowMs
        guard now - lastCaptureTime >= 400 else { return }
        lastCaptureTime = now

        // Aşamalar ölçülüyor: 2026-08-25'te uygulama video kuyruğunda 77 saniye tamamen durdu ve
        // hangi çağrının tıkadığını ancak süre kaydı söyleyebilir (cihazda debugger yok).
        guard let fullCG = preparedCG ?? analyzer.timing.measure("tamKare", { cgImage(from: frame.pixelBuffer) }) else { return }
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
        guard let aligned = analyzer.timing.measure("hizalama", {
            FaceAligner.alignedImage(from: crop, leftEye: leftEyeInCrop, rightEye: rightEyeInCrop)
        }) else { return }

        // Netlik (112×112 aligned) → anlık "net değil" uyarısı + best-frame için kalite bonusu.
        let sharpness = analyzer.timing.measure("netlik", { Self.sharpness(of: aligned) })
        blurWarning = (sharpness >= 0 && sharpness <= Self.blurWarnThreshold)
            ? NSLocalizedString("liveness_quality_blur", comment: "") : nil
        publishWarning()
        let sharpBonus: Float = sharpness >= 0 ? min(max(sharpness / Self.sharpQualityRef, 0), 1) * 15 : 0
        // Eşit benzerlikte best-frame seçimini en NET kareye kaydır (poz + netlik birleşik).
        let effQuality = min(quality + sharpBonus, 115)

        var currentMatch: Float = 0
        if let chipEmbedding, let selfieEmb = analyzer.timing.measure("embedding", { embedder.embedding(from: aligned) }) {
            currentMatch = FaceEmbedder.cosineSimilarity(chipEmbedding, selfieEmb)
        }

        var shouldSave = false
        if chipEmbedding != nil {
            if currentMatch > bestSavedMatchScore + 0.005 {
                shouldSave = true
            } else if abs(currentMatch - bestSavedMatchScore) < 0.005, effQuality > bestSavedQualityScore + 5 {
                shouldSave = true
            } else if selfieJPEG == nil {
                shouldSave = true
            }
        } else if effQuality > bestSavedQualityScore + 5 || selfieJPEG == nil {
            shouldSave = true
        }

        if shouldSave {
            // PNG (lossless): R50 girişi tam bu 112×112 pikseller; bu boyutta JPEG blok artefaktı
            // embedding'i bozabilir. (Değişken adı geçmişten "JPEG" kaldı.)
            selfieJPEG = UIImage(cgImage: aligned).pngData()
            antiSpoofCropJPEGLogic = makeAntiSpoofCrop(fullCG: fullCG, box: box)
            let faceFrac = frame.imageSize.width > 0 ? Float(box.width / frame.imageSize.width) : -1
            savedFrameMetrics =
                "luma=\(Int(lastLuma)) sharp=\(Int(sharpness)) quality=\(Int(effQuality)) " +
                "yaw=\(Int(frame.signals.yaw)) pitch=\(Int(frame.signals.pitch)) " +
                "roll=\(Int(frame.signals.roll)) faceW=\(Int(faceFrac * 100))%"
            bestSavedMatchScore = currentMatch
            bestSavedQualityScore = effQuality
            if currentMatch > bestMatchScore { bestMatchScore = currentMatch }
            if currentMatch > Self.matchThreshold { isIdentityVerified = true }

            // Kaydedilen kare değişti → 1. adayın ölçüleri de bu karenin ölçüleri.
            let frameMetrics = SimilarityStreamer.metricsOf(
                deviceMatchScore: min(max(Int(currentMatch * 100), 0), 100),
                luma: Int(lastLuma),
                sharpness: Int(sharpness),
                quality: Int(effQuality),
                yaw: Int(frame.signals.yaw),
                pitch: Int(frame.signals.pitch),
                roll: Int(frame.signals.roll),
                faceWidthRatio: Int(faceFrac * 100),
                gestureCount: progressSteps,
                wrongGestureCount: progressWrong,
                elapsedMs: runStartedAtMs > 0 ? Int(Self.nowMs - runStartedAtMs) : nil)
            bestFrameMetrics = frameMetrics

            // Canlı benzerlik akışı: en iyi kare YENİLENDİĞİNDE enclave'e gönderilir. Selfie ve
            // kırpma AYNI kareden gelir (aksi bir açık olurdu).
            if let selfie = selfieJPEG {
                streamer?.submitFrame(selfie: selfie, crop: antiSpoofCropJPEGLogic, metrics: frameMetrics)
            }
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
        let metrics = savedFrameMetrics
        // Başarıda da üretilir: sunucudaki anti-spoof reddi bu adımdan SONRA geliyor.
        let summary = makeDiagnosticsSummary(reason: nil)
        let hasSelfie = selfieJPEG != nil
        // ⚠️ SUBMIT'İN İKİ YOLU VAR (canlı benzerlik akışı): (1) cihaz skoru 0.65'i geçti →
        // isIdentityVerified, (2) enclave "benzerlik geçti" dedi → streamer.hasEnclaveApproval.
        // İkincisi bir güvenlik gevşemesi DEĞİLDİR: cihazdaki 0.65 hiçbir zaman güvenlik kontrolü
        // değildi ve gerçek karar hep enclave'de. Android `LivenessActivity.finishSuccess` paritesi.
        let verified = isIdentityVerified || (streamer?.hasEnclaveApproval == true)
        // Çip fotoğrafı VERİLMİŞSE kapı aranır — embedding üretilemediyse de (parite denetimi O-5).
        let hasChip = chipEmbedding != nil || chipDecodeFailed
        let score = bestMatchScore
        let jpeg = selfieJPEG
        let cropJPEG = antiSpoofCropJPEGLogic
        let proof = choreographyProofLogic

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidateWatchdog()
            self.camera.stop()
            self.finalMatchScore = score
            self.diagnosticsSummary = summary
            if !hasSelfie {
                self.phase = .failure(.noSelfie)
                return
            }
            if hasChip && !verified {
                self.phase = .failure(.matchFailed)
                return
            }
            if let jpeg { self.alignedSelfieJPEG = jpeg }
            self.antiSpoofCropJPEG = cropJPEG
            self.choreographyProof = proof
            Log.info("Liveness başarı: score=\(Int(score * 100))% verified=\(verified) " +
                     "adım=\(proof?.steps.count ?? 0) [\(metrics ?? "kare ölçüsü yok")]", category: .liveness)
            self.feedback.play(.done)
            // Akış bitti — gömme vektörünü serbest bırak ve akışın NASIL bittiğini bildir.
            self.streamer?.release(outcome: "submitted")
            self.phase = .success
        }
    }

    /// Hareketin sonucunu huniye bildirir: hangi hareket, kaç ms sürdü, kaç yanlıştan sonra.
    /// Satırlar AKIŞLA büyür, kareyle değil — `(flow_id, step)` benzersiz, akış başına bir kez.
    private func reportEvent(_ event: EventSequencer.Event, durationMs: Int, wrongCount: Int, timedOut: Bool) {
        guard !isDemo, let nonce = flowNonce else { return }
        Task { await FlowTelemetry.shared.gestureResolved(event.telemetryStep, durationMs: durationMs,
                                                          wrongCount: wrongCount, timedOut: timedOut,
                                                          nonce: nonce) }
    }

    /// Teşhis özetini üretir. ⚠️ VİDEO KUYRUĞUNDAN çağrılır: okuduğu alanlar logic-state'tir.
    private func makeDiagnosticsSummary(reason: FailureReason?) -> String {
        let chip: String
        if chipEmbedding != nil { chip = "var" }
        else if chipPhotoData == nil { chip = "yok" }
        else { chip = "çözülemedi" }
        var line = "Canlılık / Liveness: skor=%\(Int(bestMatchScore * 100))"
            + " (cihaz eşiği %\(Int(Self.matchThreshold * 100)))"
            + " adım=\(progressSteps)/\(events.count)"
            + " yanlış=\(progressWrong)"
            + " çip=\(chip)"
        if let reason { line += " sebep=\(reason.flowReason)" }
        return line + "\nKare / Frame: " + (savedFrameMetrics ?? "kare kaydedilmedi")
    }

    /// Video kuyruğundan (ya da bekçiden) çağrılır, sonucu ana kuyruğa taşır.
    private func finalizeFailure(_ reason: FailureReason) {
        let metrics = savedFrameMetrics
        let score = bestMatchScore
        let summary = makeDiagnosticsSummary(reason: reason)
        // Parlaklık da eklenir: ML Kit hiç yüz bulamadığında ayırt edilmesi gereken ilk şey
        // görüntünün BOŞ olup olmadığı.
        let diag = analyzer.diagnostics + " luma=\(Int(lastLuma))"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.phase == .running else { return }   // çift tetiklenmeye karşı
            self.invalidateWatchdog()
            self.camera.stop()
            self.finalMatchScore = score
            self.diagnosticsSummary = summary
            Log.warning("Liveness başarısız (\(reason)) — bestScore=\(Int(score * 100))% " +
                        "[\(metrics ?? "kare ölçüsü yok")] \(diag)", category: .liveness)
            // Ölçüm tablosuna GERÇEK sebep gider; stop()'taki "abandoned" bunu ezemez.
            self.streamer?.release(outcome: reason.flowReason)
            self.phase = .failure(reason)
        }
    }

    // MARK: - Demo (ana kuyruk)

    /// Demo: gerçek hareket/selfie gerekmez — her adımı 1sn sonra otomatik onayla (Android demo).
    private func presentDemoStep(_ step: Int) {
        guard phase == .running else { return }
        if step >= events.count {
            invalidateWatchdog()
            camera.stop()
            // Demo selfie gerektirmez. Ama yüz yakalanmadıysa alignedSelfieJPEG nil kalır ve View'ın
            // onSuccess koşulu sağlanmaz → ekran durmuş kamerada kilitlenir. Boş yer tutucu ver.
            if alignedSelfieJPEG == nil { alignedSelfieJPEG = Data() }
            feedback.play(.done)
            phase = .success
            return
        }
        stepText = "\(step + 1)/\(events.count)"
        instruction = Self.eventText(events[step])
        subInstruction = Self.eventHint(events[step])
        checkmark = false
        frameAligned = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .running else { return }
            self.feedback.play(.stepOk)   // demo gerçek akışı temsil etmeli (aynı ses/haptic)
            self.checkmark = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.presentDemoStep(step + 1) }
        }
    }

    // MARK: - Bekçi (ana kuyruk)

    /// Kare akışı durursa (kamera takıldı) akışı bitirir. Dizinin saati kare döngüsünde işliyor —
    /// kare gelmezse o da durur; bu bekçi kullanıcıyı donmuş bir ekranda bırakmamak için.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .running, !self.isDemo else { return }
            let idle = Date().timeIntervalSince1970 * 1000 - self.lastFrameAtMs
            guard idle > Self.stallTimeout * 1000 else { return }
            self.invalidateWatchdog()
            // Video kuyruğuna SIÇRAMADAN bitir: sıçrama tıkalıysa "Süre doldu" ekranı da gecikirdi.
            self.finalizeFailure(.sessionTimeout)
        }
    }

    private func invalidateWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Görüntü yardımcıları

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// MiniFASNetV2 için 2.7x geniş 80x80 JPEG crop (Android AntiSpoofCrop portu).
    private func makeAntiSpoofCrop(fullCG: CGImage, box: CGRect) -> Data? {
        let cx = box.midX, cy = box.midY
        let halfW = box.width * 2.7 / 2
        let halfH = box.height * 2.7 / 2
        let left   = max(0, cx - halfW)
        let top    = max(0, cy - halfH)
        let right  = min(CGFloat(fullCG.width),  cx + halfW)
        let bottom = min(CGFloat(fullCG.height), cy + halfH)
        let asRect = CGRect(x: left, y: top, width: right - left, height: bottom - top).integral
        guard asRect.width > 0, asRect.height > 0,
              let wideCrop = fullCG.cropping(to: asRect) else { return nil }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 80, height: 80), true, 1)
        UIImage(cgImage: wideCrop).draw(in: CGRect(x: 0, y: 0, width: 80, height: 80))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return scaled?.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Ortam kalitesi (ışık) — Android LivenessAnalyzer.averageLuma karşılığı

    /// Her karede ortalama parlaklığı ölçer ve karanlık/aşırı-parlak uyarısını günceller.
    /// Video kuyruğunda çağrılır (Android onFrameLuma ile aynı disiplin).
    private func updateQualityWarning(for pixelBuffer: CVPixelBuffer) {
        let luma = Self.averageLuma(pixelBuffer)
        lastLuma = luma

        // "Yüzünüz çerçevede değil" — ışık/netlik uyarılarının ÖNÜNDE gelir. Uygulama kare
        // gelmediğini zaten biliyorken susup faturayı kullanıcıya kesmemeli.
        let now = Self.nowMs
        let runningLongEnough = sequencer != nil && runStartedAtMs > 0 && now - runStartedAtMs > Self.noFaceGraceMs
        let faceGone = lastFaceTime == 0 || now - lastFaceTime > Self.noFaceWarnMs
        faceMissingWarning = (!isDemo && runningLongEnough && faceGone)
            ? NSLocalizedString("liveness_quality_no_face", comment: "")
            : nil
        if luma < 55 {
            lumaWarning = NSLocalizedString("liveness_quality_dark", comment: "")
        } else if luma > 235 {
            lumaWarning = NSLocalizedString("liveness_quality_bright", comment: "")
        } else {
            lumaWarning = nil
        }
        publishWarning()
    }

    /// Yüz (öncelikli) + ışık + netlik uyarısını tek label'da birleştirir.
    private func publishWarning() {
        // Sıra önemli: yüz kadrajda değilken "ortam karanlık" demek yanlış hedefi gösterir.
        let w = faceMissingWarning ?? lumaWarning ?? blurWarning
        DispatchQueue.main.async { [weak self] in
            guard let self, self.qualityWarning != w else { return }
            self.qualityWarning = w
        }
    }

    // MARK: - Netlik (blur) ölçümü — Android computeSharpness karşılığı

    static let blurWarnThreshold: Float = 45
    static let sharpQualityRef: Float = 250   // bu enerjide tam +15 kalite bonusu

    /// 112×112 yüz CGImage'ında ileri-fark gradyan enerjisi (Brenner benzeri). Yüksek = net.
    static func sharpness(of cg: CGImage) -> Float {
        let w = cg.width, h = cg.height
        guard w >= 4, h >= 4 else { return -1 }
        var gray = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Double = 0
        var count = 0
        var y = 1
        while y < h - 1 {
            let row = y * w
            var x = 1
            while x < w - 1 {
                let c = Int(gray[row + x])
                let gx = Int(gray[row + x + 1]) - c
                let gy = Int(gray[row + w + x]) - c
                sum += Double(gx * gx + gy * gy)
                count += 1
                x += 2
            }
            y += 2
        }
        return count > 0 ? Float(sum / Double(count)) : -1
    }

    /// BGRA pixel buffer'dan ~2048 örnekle ortalama parlaklık (0..255). Hatada 128 (nötr).
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
