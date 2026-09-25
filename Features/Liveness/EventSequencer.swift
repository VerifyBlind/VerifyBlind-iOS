import CoreGraphics
import Foundation

/// OLAY DİZİSİ — Android `util/EventCollector` portu. **Saf mantık:** kamera, görüntü işleme ve ağ
/// yok; zaman dışarıdan verilir → XCTest'te kamerasız, deterministik sınanır.
///
/// ## Neden
///
/// Sunucu diziyi nonce'tan türetir (dört hareketten üçü, hepsi farklı, rastgele sıra). Her
/// hareketten ÖNCE bir nötr kare, hareket ANINDA olay karesi toplanır; enclave aynı nonce'tan diziyi
/// yeniden türetip kareleri ona göre ölçer ve HER karede kart sahibinin yüzünü arar. Kapattığı açık
/// kaynak ayrımı: benzerliği kart sahibinin fotoğrafı, hareketi başka bir yüz sağlayamaz — fotoğraf
/// ise hareket yapamaz.
///
/// 🔴 Mesafe YOK (2026-09-25). İki mesafede görüntüden 3B çıkarmak FaceTec patent istemlerine
/// düşüyor. Yüz boyutu kontrolü yalnız KALİTE içindir — tek bir aralık, farklı mesafe hedefleri değil.
///
/// ## Kurallar (Android ile birebir)
///
/// | olay | tepki |
/// |---|---|
/// | yüz çerçevede değil / çok küçük / çok büyük | hareket istenmez, ne yapılacağı söylenir |
/// | yüz gergin (gülümsüyor, gözler kapalı, ağız açık) | "yüzünüzü gevşetin" — nötr kare ancak sonra |
/// | yanlışını yaptı | yanlış sayacı +1, AYNI adım devam |
/// | yüz kadrajdan çıktı | **yalnız o adım** baştan (≤ `maxResets` toplam) |
/// | süre doldu | akış biter |
///
/// İstemsiz göz kırpma ASLA cezalandırılmaz; ağız açma istenirken gülümseme yanlış sayılmaz
/// (ML Kit açık ağzı gülümseme sanıyor).
struct EventSequencer {

    enum Event: Int, CaseIterable {
        case blink = 1
        case smile = 2
        case mouthOpen = 3
        case doubleBlink = 4

        /// Olayın kaç kare istediği — enclave'in yapı kuralıyla AYNI.
        var frames: Int { self == .doubleBlink ? 2 : 1 }

        var telemetryStep: FlowTelemetry.Step {
            switch self {
            case .blink: return .gestureBlink
            case .smile: return .gestureSmile
            case .mouthOpen: return .gestureMouthOpen
            case .doubleBlink: return .gestureDoubleBlink
            }
        }

        var traceName: String {
            switch self {
            case .blink: return "blink"
            case .smile: return "smile"
            case .mouthOpen: return "mouth_open"
            case .doubleBlink: return "double_blink"
            }
        }
    }

    enum Phase: Equatable {
        /// Yüzü yerleştir, gevşet, sabit dur — nötr kare bundan sonra.
        case settle
        /// İstenen hareket bekleniyor.
        case event
        /// Hareket tuttu — kısa onay, sonra sıradaki adım.
        case afterEvent
        case done
    }

    /// Yüzün kadrajdaki durumu — yalnız KALİTE için (tek aralık).
    enum Framing: Equatable { case ok, tooSmall, tooLarge, offFrame }

    enum Failure: Equatable {
        case settleTimeout, eventTimeout, tooManyWrong, tooManyResets
    }

    /// Tek seferlik bildirimler — çağıran sunuma taşır.
    enum Signal: Equatable {
        case stepDone
        case wrong(Event)
        case stepReset(String)
        case resolved(Event, durationMs: Int, wrongCount: Int, timedOut: Bool)
        case failed(Failure)
        case completed
    }

    struct Step: Equatable {
        var neutral: Data?
        var events: [Data] = []
        var wrong = 0
    }

    // MARK: Sabitler (Android EventCollector ile AYNI sayılar)

    /// Nötr kare ancak yüz bu kadar süre yerinde ve hareketsiz kalınca alınır.
    static let stillWindowMs: Double = 500
    /// Hareketsizlik penceresinde yüz genişliğinin oynayabileceği pay.
    static let stillTolerance: Double = 0.08
    /// Hareketten sonra sıradaki adıma geçmeden önceki onay süresi.
    static let afterEventMs: Double = 700
    /// Yüz genişliği / kadraj genişliği — KALİTE aralığı. Tek aralık: mesafe DEĞİŞİMİ istenmiyor.
    static let minFaceFraction: CGFloat = 0.28
    static let maxFaceFraction: CGFloat = 0.80
    /// Yüz kutusunun kadraj dışına taşabileceği pay.
    static let edgeTolerance: CGFloat = 0.04
    static let settleTimeoutMs: Double = 20_000
    static let eventTimeoutMs: Double = 12_000
    /// Yüz bu kadar kayıp kalırsa adım baştan.
    static let faceLostMs: Double = 1_200
    static let maxResets = 3
    /// Toplam yanlış olay bütçesi — eski jest akışıyla aynı.
    static let maxWrong = 5
    /// Tek adımda yanlış olay sınırı — tekrar sınırı UX değil GÜVENLİK parametresi.
    static let maxWrongPerStep = 3
    /// Kapalı göz eşiği — 100-150 ms'lik kırpma çoğu zaman yarı kapalıyken örnekleniyor.
    static let eyeClosed: Float = 0.20
    static let eyeOpen: Float = 0.5
    static let smileOn: Float = 0.8
    static let smileNeutral: Float = 0.4
    /// Ağız açıklığı (ML Kit dudak konturu, bkz. `FaceAnalyzer.innerLipOpen`): en az bu değer VE
    /// nötrden en az `mouthOpenDelta` fazla. Nötr = yerleşme sırasındaki ölçümlerin ORTANCASI.
    static let mouthOpenMin: Float = 0.20
    static let mouthOpenDelta: Float = 0.15
    static let mouthRelaxDelta: Float = 0.08
    static let mouthSamples = 25
    /// Çift kırpmada iki kırpma arası en fazla / en az.
    static let doubleBlinkWindowMs: Double = 2_000
    static let doubleBlinkMinGapMs: Double = 150
    static let maxTraceChars = 3_500
    static let eventSampleMs: Double = 300

    // MARK: Durum

    let events: [Event]
    private(set) var phase: Phase = .settle
    private(set) var index = 0
    private(set) var steps: [Step]
    private(set) var framing: Framing = .offFrame
    private(set) var settling = false
    private(set) var needsRelax = false
    private(set) var eventCount = 0
    private(set) var resets = 0
    private(set) var wrongEvents = 0
    /// Son `tick`'te hesaplanan kalan süre oranı (1 → tam, 0 → doldu).
    private(set) var timeLeft: Double = 1
    private(set) var trace = ""

    private var startedAt: Double = 0
    private var phaseStartedAt: Double = 0
    private var eventStartedAt: Double = 0
    private var afterEventAt: Double = 0
    private var lastFaceAt: Double = 0
    private var commandShownAt: Double = 0
    private var stillSamples: [(t: Double, w: Double)] = []
    private var lastFraming: Framing?
    private var mouthSampleList: [Float] = []
    private var mouthNeutral: Float?
    private var smileArmed = false
    private var rearmRequired = false
    private var eyesClosed = false
    private var blinkCount = 0
    private var firstBlinkAt: Double = 0
    private var lastSampleAt: Double = 0
    private var eventFrames = 0

    init(events: [Event]) {
        self.events = events
        self.steps = Array(repeating: Step(), count: events.count)
    }

    var isActive: Bool { phase != .done }
    var completedSteps: Int { index }
    var currentEvent: Event? { events.isEmpty ? nil : events[min(index, events.count - 1)] }

    /// Bu karede dudak konturu ölçülsün mü — yalnız ağız açma adımında (ikinci dedektör pahalı).
    var wantsContour: Bool {
        (phase == .settle || phase == .event) && index < events.count && events[index] == .mouthOpen
    }

    /// Olay bekleniyor — çağıran bu sırada ağır işleri (selfie adayı, gömme) ERTELEMELİ: kare
    /// hızı düşerse 100-150 ms'lik bir kırpma iki kare arasında kalır.
    var quietPhase: Bool { phase == .event }

    // MARK: Akış

    mutating func start(now: Double) {
        startedAt = now
        phaseStartedAt = now
        phase = .settle
        index = 0
        framing = .offFrame
        record("start " + events.map { $0.traceName }.joined(separator: ","), now: now)
    }

    /// Yüz bulunan kare. `capture`, istenen anın kırpılmış JPEG'ini döndürür; nil dönerse karar bu
    /// karede alınmaz (sonraki karede yeniden denenir).
    mutating func offer(_ s: FaceSignals, frameSize: CGSize, now: Double,
                        capture: () -> Data?) -> [Signal] {
        guard phase != .done else { return [] }
        lastFaceAt = now
        // Sınıflandırma gelmediyse bu kare ölçüm DEĞİLDİR (bkz. FaceSignals.landmarksOK).
        guard s.landmarksOK else { return [] }

        switch phase {
        case .settle: return handleSettle(s, frameSize: frameSize, now: now, capture: capture)
        case .event: return handleEvent(s, now: now, capture: capture)
        case .afterEvent: return now - afterEventAt >= Self.afterEventMs ? nextStep(now: now) : []
        case .done: return []
        }
    }

    /// Kare akışının saati — yüz bulunsun bulunmasın her karede çağrılır.
    mutating func tick(now: Double) -> [Signal] {
        guard phase != .done else { return [] }

        // Onay anında adım zaten tamam — yüz kaybı onu silmemeli.
        if phase == .afterEvent {
            return now - afterEventAt >= Self.afterEventMs ? nextStep(now: now) : []
        }

        if lastFaceAt > 0, now - lastFaceAt > Self.faceLostMs, hasCaptureInStep {
            return resetStep("face_lost", now: now)
        }

        let (limit, since) = phase == .event
            ? (Self.eventTimeoutMs, eventStartedAt)
            : (Self.settleTimeoutMs, phaseStartedAt)
        timeLeft = max(0, min(1, 1 - (now - since) / limit))
        guard timeLeft <= 0 else { return [] }

        if phase == .event {
            let resolved = Signal.resolved(events[index], durationMs: Int(now - commandShownAt),
                                           wrongCount: steps[index].wrong, timedOut: true)
            return [resolved] + fail(.eventTimeout, now: now)
        }
        return fail(.settleTimeout, now: now)
    }

    mutating func abandon(now: Double) {
        guard phase != .done else { return }
        phase = .done
        record("abandon", now: now)
    }

    // MARK: Aşamalar

    private mutating func handleSettle(_ s: FaceSignals, frameSize: CGSize, now: Double,
                                       capture: () -> Data?) -> [Signal] {
        let f = Self.framing(of: s.boundingBox, in: frameSize)
        framing = f
        if f != lastFraming {
            record("e\(index) frame \(f)", now: now)
            lastFraming = f
        }
        needsRelax = false
        guard f == .ok else {
            stillSamples.removeAll()
            settling = false
            return []
        }

        if let lip = s.lipOpen {
            mouthSampleList.append(lip)
            if mouthSampleList.count > Self.mouthSamples { mouthSampleList.removeFirst() }
        }

        // Nötr yüz: gözler açık, gülümsemiyor, ağız kapalı (ağız yalnız ağız açma adımında ölçülüyor).
        let relaxed = eyesOpen(s) && s.smile < Self.smileNeutral &&
            (s.lipOpen.map { $0 < Self.mouthOpenMin } ?? true)

        let w = Double(s.boundingBox.width)
        stillSamples.append((t: now, w: w))
        stillSamples.removeAll { $0.t < now - Self.stillWindowMs }
        let covered = stillSamples.count >= 3 &&
            now - (stillSamples.first?.t ?? now) >= Self.stillWindowMs * 0.8
        let widths = stillSamples.map { $0.w }
        let spread: Double
        if let lo = widths.min(), let hi = widths.max(), lo > 0 { spread = (hi - lo) / lo } else { spread = 1 }
        let still = covered && spread <= Self.stillTolerance

        guard relaxed else {
            needsRelax = true
            settling = false
            return []
        }
        settling = !still
        guard still, let path = capture() else { return [] }

        steps[index].neutral = path
        mouthNeutral = Self.median(mouthSampleList)
        record("e\(index) neutral sm=\(Self.f2(s.smile)) mouth0=\(Self.f2(mouthNeutral))", now: now)
        beginEvent(s, now: now)
        return []
    }

    private mutating func beginEvent(_ s: FaceSignals, now: Double) {
        phase = .event
        eventStartedAt = now
        if commandShownAt == 0 { commandShownAt = now }
        lastSampleAt = 0
        eventFrames = 0
        blinkCount = 0
        eventCount = 0
        eyesClosed = eyesClosedNow(s)
        smileArmed = s.smile < Self.smileNeutral
        rearmRequired = false
        needsRelax = false
        timeLeft = 1
        record("e\(index) ev \(events[index].traceName)", now: now)
    }

    private mutating func handleEvent(_ s: FaceSignals, now: Double, capture: () -> Data?) -> [Signal] {
        eventFrames += 1
        let demanded = events[index]
        let closed = eyesClosedNow(s)
        let open = eyesOpen(s)
        if mouthNeutral == nil, let lip = s.lipOpen { mouthNeutral = lip }
        let mouthOpen: Bool
        let mouthRelaxed: Bool
        if let lip = s.lipOpen {
            mouthOpen = lip >= Self.mouthOpenMin && (mouthNeutral.map { lip - $0 >= Self.mouthOpenDelta } ?? true)
            mouthRelaxed = mouthNeutral.map { lip - $0 <= Self.mouthRelaxDelta } ?? true
        } else {
            mouthOpen = false
            mouthRelaxed = true
        }
        if s.smile < Self.smileNeutral { smileArmed = true }
        let smileRise = smileArmed && s.smile > Self.smileOn

        // Olay sırasında sinyal örneği — eşikleri kalibre etmenin tek yolu.
        if now - lastSampleAt >= Self.eventSampleMs {
            lastSampleAt = now
            record("s \(Self.f2(s.leftEyeOpen))/\(Self.f2(s.rightEyeOpen)) sm=\(Self.f2(s.smile)) lip=\(Self.f2(s.lipOpen))", now: now)
        }

        // Kapanış kenarı: yeni bir kırpma, açık → kapalı geçişidir.
        let closing = closed && !eyesClosed
        if closed { eyesClosed = true } else if open { eyesClosed = false }

        if rearmRequired {
            if s.smile < Self.smileNeutral && mouthRelaxed {
                rearmRequired = false
                smileArmed = true
                needsRelax = false
                record("e\(index) rearmed", now: now)
            }
            return []
        }

        // Çift kırpmada ilk kırpmanın ardından sessizlik: istemsiz kırpmaydı, sessizce sıfırla.
        if demanded == .doubleBlink, blinkCount == 1, now - firstBlinkAt > Self.doubleBlinkWindowMs {
            steps[index].events.removeAll()
            blinkCount = 0
            eventCount = 0
            record("e\(index) dbl timeout", now: now)
        }

        // 1) İstenen olay önce: aynı karede başka bir şey de olsa istenen yapıldıysa GEÇER.
        let satisfied: Bool
        switch demanded {
        case .blink: satisfied = closing
        case .doubleBlink: satisfied = closing && (blinkCount == 0 || now - firstBlinkAt >= Self.doubleBlinkMinGapMs)
        case .smile: satisfied = smileRise
        case .mouthOpen: satisfied = mouthOpen
        }
        if satisfied {
            guard let frame = capture() else { return [] }
            steps[index].events.append(frame)
            if demanded == .doubleBlink {
                blinkCount += 1
                if blinkCount == 1 {
                    firstBlinkAt = now
                    eventCount = 1
                    record("e\(index) dbl 1/2", now: now)
                    return []
                }
            }
            let secs = max(1, now - eventStartedAt) / 1000
            record("e\(index) ok sm=\(Self.f2(s.smile)) lip=\(Self.f2(s.lipOpen)) " +
                   "fps=\(String(format: "%.1f", Double(eventFrames) / secs))", now: now)
            let resolved = Signal.resolved(demanded, durationMs: Int(now - commandShownAt),
                                           wrongCount: steps[index].wrong, timedOut: false)
            phase = .afterEvent
            afterEventAt = now
            return [resolved, .stepDone]
        }

        // 2) Yanlış olay — yalnız GÜVENİLİR biçimde ayırt edilebilen KASITLI hareketler.
        //  - Göz kırpma asla yanlış sayılmaz (istemsiz).
        //  - Ağız açma istenirken gülümseme yanlış SAYILMAZ (ML Kit açık ağzı gülümseme sanıyor).
        //  - Ağız açma yalnız ağız açma adımında ölçülüyor; başka adımda yanlış olarak aranmıyor.
        if (demanded == .blink || demanded == .doubleBlink) && smileRise {
            record("e\(index) wrong smile sm=\(Self.f2(s.smile))", now: now)
            return onWrong(.smile, now: now)
        }
        return []
    }

    private mutating func onWrong(_ event: Event, now: Double) -> [Signal] {
        wrongEvents += 1
        steps[index].wrong += 1
        steps[index].events.removeAll()
        blinkCount = 0
        eventCount = 0
        rearmRequired = true
        needsRelax = true
        eventStartedAt = now   // yeni deneme için tam süre
        if wrongEvents >= Self.maxWrong || steps[index].wrong >= Self.maxWrongPerStep {
            return fail(.tooManyWrong, now: now)
        }
        return [.wrong(event)]
    }

    private mutating func nextStep(now: Double) -> [Signal] {
        record("e\(index) done", now: now)
        index += 1
        if index >= events.count {
            phase = .done
            record("finish", now: now)
            return [.completed]
        }
        enterSettle(now: now)
        return []
    }

    /// Yüz kayboldu → YALNIZ BU ADIM baştan. Tamamlanan adımlar korunur: her karede kimliği enclave
    /// doğruluyor. Adımın yanlış hareket sayısı korunur — tekrar, bütçeyi sıfırlamanın yolu olmasın.
    private mutating func resetStep(_ reason: String, now: Double) -> [Signal] {
        resets += 1
        record("reset e\(index) \(reason)", now: now)
        steps[index].neutral = nil
        steps[index].events.removeAll()
        if resets > Self.maxResets { return fail(.tooManyResets, now: now) }
        enterSettle(now: now)
        framing = .offFrame
        return [.stepReset(reason)]
    }

    private mutating func enterSettle(now: Double) {
        phase = .settle
        phaseStartedAt = now
        commandShownAt = 0
        stillSamples.removeAll()
        mouthSampleList.removeAll()
        mouthNeutral = nil
        lastFraming = nil
        settling = false
        needsRelax = false
        eventCount = 0
        timeLeft = 1
    }

    private mutating func fail(_ failure: Failure, now: Double) -> [Signal] {
        guard phase != .done else { return [] }
        phase = .done
        record("fail \(failure) e\(index)", now: now)
        return [.failed(failure)]
    }

    // MARK: Yardımcılar

    private var hasCaptureInStep: Bool {
        index < steps.count && (steps[index].neutral != nil || !steps[index].events.isEmpty)
    }

    /// Yüzün kadrajdaki durumu (kutu ve kadraj aynı, dik piksel uzayında).
    static func framing(of box: CGRect, in frame: CGSize) -> Framing {
        guard frame.width > 0, frame.height > 0 else { return .offFrame }
        let tolX = frame.width * edgeTolerance
        let tolY = frame.height * edgeTolerance
        if box.minX < -tolX || box.minY < -tolY || box.maxX > frame.width + tolX || box.maxY > frame.height + tolY {
            return .offFrame
        }
        let fraction = box.width / frame.width
        if fraction < minFaceFraction { return .tooSmall }
        if fraction > maxFaceFraction { return .tooLarge }
        return .ok
    }

    /// Kırpma sayılan kapanış: gözlerden BİRİNİN kapanması yeter (2026-09-25, kullanıcı kararı).
    /// Komut emojisi (😉) tek göz kırpmayı gösteriyor ve sahada tek gözle kırpan algılanmadı.
    /// Güvenlik kaybı yok: fotoğraf tek gözünü de kırpamaz; istenen, komuta canlı bir tepki.
    /// Açılış (kenarın sıfırlanması, `eyesOpen`) İKİ gözün de açılmasını ister — tek göz
    /// kırpmanın ortasında sayaç ikinci kez tetiklenmesin. Android `EventCollector.isClosing`.
    private func eyesClosedNow(_ s: FaceSignals) -> Bool {
        min(s.leftEyeOpen, s.rightEyeOpen) < Self.eyeClosed
    }

    private func eyesOpen(_ s: FaceSignals) -> Bool {
        s.leftEyeOpen > Self.eyeOpen && s.rightEyeOpen > Self.eyeOpen
    }

    /// İz kaydına bir satır: "zaman(s) mesaj;". Tavanı aşarsa bir kez "..." konur. ASCII tutulur.
    private mutating func record(_ message: String, now: Double) {
        guard trace.count < Self.maxTraceChars else { return }
        let tenths = startedAt > 0 ? Int((now - startedAt) / 100) : 0
        let line = "\(tenths / 10).\(tenths % 10) \(message);"
        if trace.count + line.count > Self.maxTraceChars {
            trace += "..."
            return
        }
        trace += line
    }

    static func f2(_ v: Float?) -> String {
        guard let v else { return "-" }
        return String(format: "%.2f", v)
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Olay dizisi karesinin yüz çevresinden kırpılması — Android `util/FaceCrop` ile AYNI kural.
///
/// Mesafe tabanlı ölçüm arka planı istiyordu, kareler tam gidiyordu. Artık yalnız yüz ölçülüyor:
/// kırpma enclave'e aynı bayt bütçesinde daha çok yüz pikseli verir ve kullanıcının odasını
/// gereksiz yere taşımaz.
enum FaceCrop {
    /// Kırpma karesinin kenarı = yüz kutusunun uzun kenarı × bu kat. Kafa, saç ve çene sığsın.
    static let scale: CGFloat = 2.2

    /// Yüz kutusunun çevresinde KARE bir kırpma. Kadraja sığmazsa önce içeri KAYDIRILIR, yine
    /// sığmazsa küçültülür — yüz kenardayken kırpmanın merkezden kaymasını kabul ederiz, kesilmesini değil.
    static func squareAround(_ box: CGRect, width: Int, height: Int) -> CGRect {
        let side = max(1, min(Int((max(box.width, box.height) * scale).rounded()), min(width, height)))
        let cx = Int(box.midX.rounded(.down))
        let cy = Int(box.midY.rounded(.down))
        let left = min(max(cx - side / 2, 0), width - side)
        let top = min(max(cy - side / 2, 0), height - side)
        return CGRect(x: left, y: top, width: side, height: side)
    }
}
