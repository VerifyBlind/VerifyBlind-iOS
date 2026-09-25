import Foundation
import CoreGraphics
import CoreImage
import UIKit

/// Girişte canlı yüz karesi toplayan ekranın mantığı — Android `LoginFaceActivity` paritesi.
///
/// NEDEN VAR: giriş anına kadar her kontrol TELEFONUN meşru olduğunu kanıtlıyor (bilet, bağlama,
/// nonce, MAC, holder-of-key) — hiçbiri telefonu TUTAN kişiyi kanıtlamıyor. Cihaz kilidi PIN/parola
/// ile de açıldığından, telefonu açabilen biri kart sahibi adına doğrulanabiliyordu.
///
/// `LivenessViewModel` ile farkı — ve neden ayrı bir ekran:
///   • TEK HAREKET (2026-09-26, kullanıcı kararı). Eskiden hiç hareket yoktu ve tek engel pasif
///     canlılık modeliydi: televizyonda gösterilen bir FOTOĞRAF bile eşiği geçebiliyordu. Hareket
///     QR nonce'undan türetilir (`LoginEvent`); enclave nötr ve hareket karelerinde de kart
///     sahibinin yüzünü arar. Kılavuz yok — kullanıcı onu kart eklerken gördü.
///   • Tek "en iyi" kare, hareketten ÖNCE seçilir. Aday listesi, streaming yok.
///   • Cihaz-içi karşılaştırma YOK. Otoriter karar enclave'dedir; burada bir eşik uygulamak
///     yanlış-red üretirdi (canlı benzerlik akışının ilk ölçümü: 6 streaming karesinin 4'ünde
///     cihaz reddederdi, enclave hepsini geçirdi).
///
/// 🔴 K6: selfie ve anti-spoof kırpması AYNI KAREDEN üretilir. Benzerlik bir kareden, canlılık
/// başkasından alınırsa gerçek bir açık doğar — ikisi tek `captureFrame` çağrısında, tek
/// `CGImage`'dan çıkar.
///
/// İPLİK DİSİPLİNİ: `LivenessViewModel` ile aynı — kare mantığı yalnız kamera VİDEO KUYRUĞUNDA
/// koşar (`analyzer.onFace`/`onNoFace`), `@Published` sunum alanları ana kuyruğa marshal edilir.
/// Bu yüzden `@MainActor` KULLANILMAZ: kare işlemeyi ana kuyruğa taşımak throttle ve kalite
/// mantığını bozar.
///
/// 🔴 Ana kuyruktan video kuyruğuna iş `camera.runOnVideoQueue` ile ATILMAZ (yalnız kare hiç
/// gelmiyorsa yedek olarak): kareler akarken kuyruğa sonradan atılan iş saniyelerce bekletiliyor
/// (kayıt ekranında 22 ve 40 sn ölçüldü). Zaman aşımı, iptal ve referans gömmesi bir istek olarak
/// bırakılır; kare döngüsü bir sonraki karede uygular (`drainRequests`).
final class LoginFaceViewModel: ObservableObject {

    /// Kare "yeterince iyi" sayılmadan önceki en düşük netlik (112×112 gradyan enerjisi).
    /// `LivenessViewModel.blurWarnThreshold` ile aynı ölçek.
    private static let minSharpness: Float = 45

    /// Kare toplama üst sınırı — kullanıcıya tanınan AZAMİ fırsat süresi.
    ///
    /// Eşiği geçemeyen kullanıcı bu süre boyunca gözlüğünü çıkarabilir, ışığa dönebilir.
    /// Dolduğunda eldeki EN İYİ kare yine seçilir: cihaz skoru enclave kararı DEĞİLDİR
    /// (farklı model, farklı eşik) ve burada reddetmek enclave'in geçireceği kullanıcıyı kapıda
    /// durdurmak olurdu. Hiç kare yoksa giriş iptal (fail-closed). Hareketin kendi süreleri var.
    private static let captureTimeout: TimeInterval = 30

    /// Benzerlik eşiği geçildikten SONRA beklenen süre — bu 1 saniyede daha iyi kare gelirse o gider.
    private static let settleSeconds: TimeInterval = 1.0

    /**
     * "Yeterince benziyor" sınırı: ekrandaki yüzdenin yeşile döndüğü VE kare seçiminin erken
     * bitebildiği eşik. Kayıt akışındaki 0.65 ile aynı sayı.
     *
     * ⚠️ Bu bir KAPI DEĞİLDİR. Altında kalmak submit'i engellemez; yalnızca kare seçiminin hemen
     * bitmesini engeller, yani kullanıcıya düzeltme fırsatı verir. Süre dolunca eldeki en iyi
     * kare koşulsuz gider ve kararı enclave verir (ArcFace, eşik 0.20 — bu sayıyla KIYASLANAMAZ).
     */
    private static let scoreHintGood: Float = 0.65

    /// Hareket kaç kez denenebilir. Nonce ancak gönderimde tükeniyor; ekranda yeniden denemek
    /// bedava — ama sınırsız deneme, video sunan saldırgana doğru anı beklemek için sınırsız süre
    /// demek. Android `MAX_MOVE_ATTEMPTS` ile aynı.
    static let maxMoveAttempts = 3

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()
    private let embedder = FaceEmbedder()
    private let feedback = LivenessFeedback()

    @Published private(set) var statusKey = "login_face_status_looking"
    @Published private(set) var warning: String?
    /// Canlı benzerlik yüzdesi (0-100) — nil ise gösterge gizli.
    @Published private(set) var matchPercent: Int?
    /// Yüzde yeşil mi gösterilecek (yalnız sunum).
    @Published private(set) var matchIsGood = false

    // Hareket sunumu — `moveInstruction` nil iken durum satırı (`statusKey`) gösterilir.
    @Published private(set) var moveInstruction: String?
    @Published private(set) var moveHint = ""
    @Published private(set) var frameAligned = false
    /// Hareketin kalan süresi (0-1) — çerçevede erir; nil ise gösterilmez.
    @Published private(set) var timeProgress: Double?

    /**
     * Bilete mühürlü yüz referansının embedding'i — ekrandaki canlı % göstergesi için.
     *
     * ⚠️ Bu YALNIZ geri bildirimdir. Otoriter karşılaştırma enclave'de yapılır ve gerçek kapı
     * odur; buradaki sayı submit'i ENGELLEMEZ. Cihaz eşiği bir güvenlik kontrolü olamaz (yerel
     * bir sayı) ve bloklayıcı yapılırsa yanlış-red üretir: canlı benzerlik akışının ilk
     * ölçümünde cihaz 6 karenin 4'ünü reddederken enclave hepsini geçirmişti.
     *
     * Skor enclave skoruyla KIYASLANAMAZ: burada MobileFaceNet, orada ArcFace R50.
     */
    private var refEmbedding: [Float]?
    /// Oturum boyunca görülen en yüksek benzerlik — ekrandaki sayı geri düşmesin diye.
    private var bestMatchScore: Float = 0

    /// Başarı: (hizalanmış 112×112 selfie PNG, AYNI karenin 2,7× 80×80 anti-spoof JPEG'i, ölçüler,
    /// hareket kanıtı). iOS'ta kareler `Data` olarak bellekte taşınır (Android dosya yolu tutar).
    var onSuccess: ((Data, Data, DeviceFrameMetrics?, ChoreographyProof?) -> Void)?

    /// Kare/hareket alınamadı ya da kullanıcı vazgeçti → çağıran giriş isteğini GÖNDERMEZ
    /// (fail-closed). `true`: hareket algılanamadı (çağıran ona göre mesaj gösterir).
    var onFailure: ((_ moveFailed: Bool) -> Void)?

    private var selfiePNG: Data?
    private var antiSpoofCropJPEG: Data?
    private var frameMetrics: DeviceFrameMetrics?

    private var bestQuality: Float = -1
    private var lastCaptureTime: TimeInterval = 0
    private var lastLuma: Float = 0
    private var startedAt = Date()
    /// "Yeterince benziyor + kalite tamam" durumunun başladığı an; nil = henüz değil.
    private var goodSince: Date?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    /// Bilete mühürlü yüz referansı (Base64 JPEG). Referans CİHAZDAN DIŞARI ÇIKMAZ; yalnız
    /// ekranda yüzde göstermek üzere yerel embedding'e çevrilir.
    var faceRefB64: String?

    /// İstenen hareket — nil: hareketsiz biter (nonce yok / eski çağıran).
    var loginEvent: EventSequencer.Event?

    // ── Tek hareket (video kuyruğu) ──
    private var sequencer: EventSequencer?
    /// En iyi kare seçildi; kareler artık harekete gidiyor (ağır bitmap işi durdu).
    private var movePhase = false
    private var moveAttempts = 0
    private var moveStartedAtMs: Double = 0
    private var moveNudged = false
    private var moveProof: ChoreographyProof?
    private var lastMovePresentation: MovePresentation?
    private var lastPublishedTime: Double = -1

    private struct MovePresentation: Equatable {
        var instruction: String
        var hint: String
        var aligned: Bool
    }

    // ── Ana kuyruk → video kuyruğu istekleri ──
    private enum Request { case timeout, cancel }
    private let requestLock = NSLock()
    private var requests = Set<Request>()
    /// Referans gömmesi ilk karede hesaplanır (kuyruğa atılmaz).
    private var refPending = false

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    func start() {
        startedAt = Date()
        refPending = !(faceRefB64 ?? "").isEmpty

        camera.onFrame = { [weak self] buffer, _ in
            // Video kuyruğu — logic durumu burada yazılır (LivenessViewModel disiplini).
            self?.lastLuma = LivenessViewModel.averageLuma(buffer)
        }
        // ML Kit `VisionImage` CVPixelBuffer kabul etmiyor → yüz analizi ayrı kanaldan beslenir.
        // Aynı kare, aynı video kuyruğu; yalnız taşıyıcı tip farklı (LivenessViewModel ile aynı kalıp).
        camera.onSampleBuffer = { [weak self] sample, orientation in
            self?.analyzer.process(sample, orientation: orientation)
        }
        // Dudak konturu yalnız ağız açma hareketinde: ikinci dedektör kare hızını düşürür.
        analyzer.contourWanted = { [weak self] in self?.sequencer?.wantsContour == true }
        analyzer.onNoFace = { [weak self] in self?.handleNoFace() }
        analyzer.onFace = { [weak self] frame in
            self?.handleFace(frame)   // video kuyruğu
        }
        camera.start()

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.captureTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.post(.timeout)
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        camera.stop()
        feedback.deactivate()
    }

    /// Kullanıcı ekranı kapattı → kare yok, giriş gönderilmez.
    ///
    /// UI'dan (ana kuyruk) çağrılır ama `finished` video kuyruğunda yaşıyor: bayrağı oradan
    /// çevirmezsek koşan bir `captureFrame` iptali görmeyip başarıyı da bildirebilirdi.
    func cancel() { post(.cancel) }

    // MARK: - İstekler

    /// İsteği bırakır: kare döngüsü bir sonraki karede uygular. Kare hiç gelmiyorsa kuyruk boştur
    /// ve yedek sıçrama gecikmeden çalışır — ikisinden hangisi önce koşarsa isteği o tüketir.
    private func post(_ request: Request) {
        requestLock.lock()
        requests.insert(request)
        requestLock.unlock()
        camera.runOnVideoQueue { [weak self] in self?.drainRequests() }
    }

    private func take(_ request: Request) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requests.remove(request) != nil
    }

    /// Video kuyruğu — her karenin başında.
    private func drainRequests() {
        if take(.cancel) { handleCancel() }
        if take(.timeout) { handleTimeout() }
    }

    private func handleCancel() {
        guard !finished else { return }
        finished = true
        sequencer?.abandon(now: Self.nowMs)
        DispatchQueue.main.async { [weak self] in
            self?.stop()
            self?.onFailure?(false)
        }
    }

    // MARK: - Kare akışı (video kuyruğu)

    private func handleFace(_ frame: FaceAnalyzer.Frame) {
        drainRequests()
        guard !finished else { return }
        if refPending { prepareReference() }
        if movePhase { stepMove(frame) } else { captureFrame(frame) }
    }

    private func handleNoFace() {
        drainRequests()
        guard !finished, movePhase, var seq = sequencer, seq.isActive else { return }
        let signals = seq.tick(now: Self.nowMs)
        sequencer = seq
        handleMove(signals, seq)
    }

    /// Referans embedding'i BİR KEZ — ilk karede. Başarısız olursa yalnız % göstergesi kaybolur;
    /// akış aynen sürer, çünkü gerçek karşılaştırma zaten enclave'de yapılıyor.
    private func prepareReference() {
        refPending = false
        guard let b64 = faceRefB64,
              let data = Data(base64Encoded: b64),
              let cg = UIImage(data: data)?.cgImage else {
            Log.warning("Yüz referansı çözülemedi — % göstergesi kapalı", category: .liveness)
            return
        }
        // Kayıt akışındaki chip embedding ile AYNI hizalama.
        let eyes = LivenessViewModel.detectEyes(in: cg)
        guard let aligned = FaceAligner.alignedImage(
                from: cg, leftEye: eyes.left, rightEye: eyes.right) else { return }
        refEmbedding = embedder.embedding(from: aligned)
    }

    /// Tek kareden selfie + anti-spoof kırpmasını üretir. `LivenessViewModel.captureFrame` ile AYNI
    /// boru hattı (aynı marj, aynı hizalama, aynı 2,7× oran ve boyutlar) — enclave iki akışta da
    /// aynı modelleri çalıştırdığı için girdi de aynı olmalı, yoksa girişteki skorlar kayıttakilerle
    /// kıyaslanamaz hâle gelir.
    private func captureFrame(_ frame: FaceAnalyzer.Frame) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastCaptureTime >= 400 else { return }
        lastCaptureTime = now

        guard let fullCG = Self.cgImage(from: frame.pixelBuffer) else { return }
        let box = frame.signals.boundingBox
        let margin = box.width * 0.4
        let left = max(0, box.minX - margin)
        let top = max(0, box.minY - margin)
        let right = min(frame.imageSize.width, box.maxX + margin)
        let bottom = min(frame.imageSize.height, box.maxY + margin)
        let w = right - left, h = bottom - top
        guard w > 50, h > 50,
              let crop = fullCG.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else { return }

        let leftEyeInCrop = frame.signals.leftEye.map { CGPoint(x: $0.x - left, y: $0.y - top) }
        let rightEyeInCrop = frame.signals.rightEye.map { CGPoint(x: $0.x - left, y: $0.y - top) }
        guard let aligned = FaceAligner.alignedImage(
            from: crop, leftEye: leftEyeInCrop, rightEye: rightEyeInCrop) else { return }

        let sharpness = LivenessViewModel.sharpness(of: aligned)
        let poseOK = abs(frame.signals.yaw) < 20 && abs(frame.signals.pitch) < 20

        // Cihaz-içi benzerlik — YALNIZ ekrandaki % için, submit'i ENGELLEMEZ (bkz. refEmbedding).
        if let refEmb = refEmbedding, let selfieEmb = embedder.embedding(from: aligned) {
            let sim = FaceEmbedder.cosineSimilarity(refEmb, selfieEmb)
            if sim > bestMatchScore { bestMatchScore = sim }
        }

        // Sunum alanları ANA kuyruğa marshal edilir — burası video kuyruğu.
        let warnText: String? =
            (sharpness >= 0 && sharpness <= Self.minSharpness) ? L.t("login_face_warn_blur")
            : (!poseOK ? L.t("login_face_warn_pose") : nil)
        let showScore = refEmbedding != nil
        let percent = Int(bestMatchScore * 100)
        let isGood = bestMatchScore >= Self.scoreHintGood
        // Durum metni ne BEKLEDİĞİMİZİ söylemeli: kalite tamamken skor düşükse sorun kadraj
        // değil benzerliktir, "sabit dur" demek yanıltıcı olurdu.
        let statusText: String
        if warnText != nil { statusText = "login_face_status_looking" }
        else if showScore && !isGood { statusText = "login_face_status_adjust" }
        else { statusText = "login_face_status_hold" }
        DispatchQueue.main.async { [weak self] in
            // Kuyrukta kalmış bir kare güncellemesi hareket ekranını ezmesin.
            guard let self, self.moveInstruction == nil else { return }
            self.warning = warnText
            self.statusKey = statusText
            self.matchPercent = showScore ? percent : nil
            self.matchIsGood = isGood
        }

        // Kalite skoru: netlik + poz. Cihaz BENZERLİK ölçmez (bloklamaz) — bu skor yalnız hangi
        // karenin enclave'e gideceğini seçer.
        let quality = (sharpness > 0 ? sharpness : 0) + (poseOK ? 50 : 0)

        // ÇIKIŞ KOŞULU: "yeterince benziyor" + 1 sn.
        //
        // Eskiden yalnız kalite (netlik+poz) yeterliydi ve ekran tatmin olur olmaz kareyi
        // gönderiyordu — kullanıcıya benzerliğini DÜZELTME fırsatı tanımadan. Gözlüğünü
        // çıkaramadan kare gidiyor, enclave reddedince kullanıcı ne yapacağını bilmiyordu.
        //
        // Referans yoksa (% hesaplanamıyorsa) eski davranışa düşülür: kalite yeterliyse gönder.
        // ⚠️ Kapı değil: eşik geçilemezse captureTimeout dolunca en iyi kare yine gider.
        let qualityOK = poseOK && sharpness > Self.minSharpness
        let readyToFinish = refEmbedding != nil ? bestMatchScore >= Self.scoreHintGood : qualityOK
        if goodSince == nil, qualityOK, readyToFinish {
            goodSince = Date()
        } else if !readyToFinish {
            goodSince = nil   // skor düştü → sayaç sıfırlanır, acele edilmez
        }
        let settled = goodSince.map { Date().timeIntervalSince($0) >= Self.settleSeconds } ?? false

        // Kalite iyileşmiyorsa yeni kare YAZILMAZ — ama elde geçerli kare varsa ve settle
        // dolduysa kare seçimi biter.
        guard quality > bestQuality else {
            if settled, selfiePNG != nil, antiSpoofCropJPEG != nil { bestFrameReady() }
            return
        }

        // PNG (lossless): ArcFace girişi tam bu 112×112 piksel; bu boyutta JPEG blok artefaktı
        // embedding'i bozabilir.
        guard let png = UIImage(cgImage: aligned).pngData(),
              let cropJPEG = Self.makeAntiSpoofCrop(fullCG: fullCG, box: box) else { return }

        selfiePNG = png
        antiSpoofCropJPEG = cropJPEG
        bestQuality = quality

        let faceFrac = frame.imageSize.width > 0 ? Float(box.width / frame.imageSize.width) : -1
        // Cihaz ölçüleri enclave'de DOĞRULANMAZ — yalnız teşhis satırına yazılır.
        // `deviceMatchScore` yalnız referans embedding'i ÜRETİLEBİLDİYSE gider; üretilemediyse nil
        // kalır, çünkü 0 göndermek ölçüm satırında "hiç benzemedi" gibi okunurdu.
        // ⚠️ Bu sayı enclave skoruyla KIYASLANAMAZ. Jest sayaçları nil — hareket kendi kanıtında.
        frameMetrics = SimilarityStreamer.metricsOf(
            deviceMatchScore: refEmbedding != nil ? min(max(Int(bestMatchScore * 100), 0), 100) : nil,
            luma: Int(lastLuma),
            sharpness: Int(sharpness),
            quality: Int(quality),
            yaw: Int(frame.signals.yaw),
            pitch: Int(frame.signals.pitch),
            roll: Int(frame.signals.roll),
            faceWidthRatio: Int(faceFrac * 100),
            gestureCount: nil,
            wrongGestureCount: nil,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000))

        if settled { bestFrameReady() }
    }

    /// Süre doldu. Elde kabul edilebilir kare varsa seçim biter: kullanıcıyı mükemmel kare için
    /// sonsuza kadar bekletmek, enclave'in zaten geçirebileceği bir kareyi çöpe atardı.
    private func handleTimeout() {
        // Hareket başladıysa kendi süreleri var (EventSequencer) — bu süre yalnız kare seçimi için.
        guard !finished, !movePhase else { return }
        if selfiePNG != nil, antiSpoofCropJPEG != nil {
            Log.info("Giriş karesi: süre doldu, eldeki en iyi kare seçildi (kalite=\(Int(bestQuality)))",
                     category: .liveness)
            bestFrameReady()
        } else {
            Log.warning("Giriş karesi: süre doldu, kullanılabilir kare yok — giriş iptal", category: .liveness)
            finish(moveFailed: false)
        }
    }

    // MARK: - Tek hareket (video kuyruğu)

    /// En iyi kare hazır. Hareket isteniyorsa sıradaki adım o; istenmiyorsa (eski çağıran) biter.
    ///
    /// Kare seçimi hareketten ÖNCE biter: hareket sırasında ağır bitmap işi (tam kare, hizalama,
    /// gömme) kare hızını düşürür ve çift kırpmanın ikincisini kaçırtır — kayıtta sahada yaşandı.
    private func bestFrameReady() {
        guard !finished, !movePhase else { return }
        guard let event = loginEvent else { succeed(); return }
        movePhase = true
        timeoutTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.matchPercent = nil
            self.warning = nil
            self.feedback.activate()   // sessiz moddayken de duyulmalı (kayıt ekranıyla aynı)
        }
        startMove(event)
    }

    private func startMove(_ event: EventSequencer.Event) {
        moveAttempts += 1
        moveNudged = false
        lastMovePresentation = nil
        lastPublishedTime = -1
        var seq = EventSequencer(events: [event])
        let now = Self.nowMs
        seq.start(now: now)
        moveStartedAtMs = now
        sequencer = seq
        presentMove(seq)
    }

    private func stepMove(_ frame: FaceAnalyzer.Frame) {
        guard var seq = sequencer, seq.isActive else { return }
        let now = Self.nowMs
        let box = frame.signals.boundingBox
        // Tam kare yalnız kırpma istendiğinde üretilir (nötr ve hareket anı).
        var fullCG: CGImage?
        var signals = seq.offer(frame.signals, frameSize: frame.imageSize, now: now) {
            if fullCG == nil { fullCG = Self.cgImage(from: frame.pixelBuffer) }
            guard let cg = fullCG else { return nil }
            return LivenessViewModel.faceCropJPEG(cg, box: box)
        }
        signals += seq.tick(now: now)
        sequencer = seq
        handleMove(signals, seq)
    }

    private func handleMove(_ signals: [EventSequencer.Signal], _ seq: EventSequencer) {
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
            case .resolved:
                break
            case .failed(let failure):
                // İz kaydı breadcrumb olarak kalır (olay değil → kota yemez).
                Log.info("Giriş hareketi başarısız: \(failure) deneme \(moveAttempts)/\(Self.maxMoveAttempts) — iz: \(seq.trace)",
                         category: .liveness)
                if moveAttempts < Self.maxMoveAttempts, let event = loginEvent {
                    feedback.play(.wrong)
                    showNotice(L.t("login_face_move_retry"))
                    startMove(event)
                } else {
                    finish(moveFailed: true)
                }
                return
            case .completed:
                moveProof = LivenessViewModel.makeProof(seq, elapsedMs: Int(Self.nowMs - moveStartedAtMs))
                Log.info("Giriş hareketi tamam: süre=\(Int(Self.nowMs - moveStartedAtMs))ms yanlış=\(seq.wrongEvents)",
                         category: .liveness)
                succeed()
                return
            }
        }
        presentMove(seq)
    }

    /// Kayıt ekranındaki yönlendirmenin aynısı — tek adım, sayaç yok. Yalnız DEĞİŞENİ yayınlar.
    private func presentMove(_ seq: EventSequencer) {
        var p = MovePresentation(instruction: "", hint: "", aligned: false)
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
            p.hint = L.t("liveness_ev_hold_hint")
        case .event:
            p.aligned = true
            if let event = seq.currentEvent {
                p.instruction = seq.needsRelax ? L.t("liveness_face_smile_relax") : LivenessViewModel.eventText(event)
                p.hint = seq.needsRelax ? L.t("liveness_ev_relax_hint")
                    : seq.eventCount == 1 ? L.t("liveness_ev_again") : LivenessViewModel.eventHint(event)
            }
        case .afterEvent:
            p.aligned = true
            p.instruction = "✅"
        case .done:
            return
        }

        if p != lastMovePresentation {
            lastMovePresentation = p
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.moveInstruction = p.instruction
                self.moveHint = p.hint
                self.frameAligned = p.aligned
            }
        }

        let left = seq.timeLeft
        if abs(left - lastPublishedTime) >= 0.01 {
            lastPublishedTime = left
            DispatchQueue.main.async { [weak self] in self?.timeProgress = left }
        }
        if left <= LivenessViewModel.lowTimeFraction && !moveNudged {
            moveNudged = true
            feedback.play(.nudge)
        }
    }

    private func showNotice(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.warning = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.warning == text { self?.warning = nil }
            }
        }
    }

    // MARK: - Bitiş (video kuyruğu)

    private func succeed() {
        guard !finished else { return }
        // Kırpma olmadan selfie GÖNDERİLMEZ: enclave canlılığı fail-closed uyguluyor, eksik kırpma
        // orada nasılsa reddedilir — kullanıcıyı ağ turu sonrası değil, burada durdur.
        guard let png = selfiePNG, let crop = antiSpoofCropJPEG else {
            finish(moveFailed: false)
            return
        }
        // Hareket istendiyse kanıtı olmadan gönderilmez — "yapamadık" asla "geçti" değildir.
        if loginEvent != nil && moveProof == nil {
            finish(moveFailed: true)
            return
        }
        finished = true
        Log.info("Giriş karesi hazır (kalite=\(Int(bestQuality)))", category: .liveness)
        let metrics = frameMetrics
        let proof = moveProof
        // Geri çağrı akış durumunu (`step`) değiştiriyor → ANA kuyruk.
        DispatchQueue.main.async { [weak self] in
            self?.stop()
            self?.onSuccess?(png, crop, metrics, proof)
        }
    }

    private func finish(moveFailed: Bool) {
        guard !finished else { return }
        finished = true
        sequencer?.abandon(now: Self.nowMs)
        DispatchQueue.main.async { [weak self] in
            self?.stop()
            self?.onFailure?(moveFailed)
        }
    }

    // MARK: - Görüntü yardımcıları (LivenessViewModel ile aynı boru hattı)

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return FaceAnalyzer.sharedCIContext.createCGImage(ci, from: ci.extent)
    }

    /// MiniFASNetV2 için 2,7× geniş 80×80 JPEG kırpma. Dar yüz kırpması ekran/fotoğraf saldırısını
    /// ayırt etmeye yetmez — model bağlam ve arka plan ister.
    private static func makeAntiSpoofCrop(fullCG: CGImage, box: CGRect) -> Data? {
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
}
