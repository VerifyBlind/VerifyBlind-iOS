import SwiftUI
import CoreImage
import CoreVideo
import Vision

/// Liveness orkestrasyonu — Android `LivenessActivity` portu.
///
/// Ön kamera + `FaceAnalyzer` ile challenge sırasını (≥5) yürütür; hareket başına 15sn (her
/// başarıda sıfırlanır) + 60sn oturum tavanı + 5 yanlış hareket bütçesi, jest ilerlemesi
/// (yanlış hareket AYNI adımı tekrarlatır; istemsiz göz kırpma sayılmaz), kare-yakalama best-frame mantığı
/// (match-iyileşmesi / kalite / ilk-kayıt) ve `MATCH_THRESHOLD=0.65`. Çıktı: hizalanmış 112×112
/// selfie JPEG + eşleşme sonucu. Chip (DG2) verilmezse %'siz çalışır (Android null-chip yolu).
///
/// İPLİK DİSİPLİNİ: TÜM logic durumu (index, skorlar, embedding) yalnız kamera VİDEO KUYRUĞUNDA
/// okunur/yazılır (`camera.runOnVideoQueue` + `analyzer.onFace`); `@Published` sunum güncellemeleri
/// daima ana kuyruğa marshalled edilir. Bu yüzden `@MainActor` KULLANILMAZ (video kuyruğu logic'i
/// ile çakışırdı).
final class LivenessViewModel: ObservableObject {

    static let matchThreshold: Float = 0.65

    /// Hareket başına süre — HER BAŞARILI HAREKETTE sıfırlanır. İlerleyen kullanıcı zamana yenilmez;
    /// yalnızca gerçekten takılan bir oturum (karanlık oda, yüz yok) sona erer. Eski tasarım 5 hareket
    /// için TEK bir 30sn sayaç kullanıyordu ve ilk kez deneyenleri yüzleri EŞLEŞMİŞKEN reddediyordu
    /// (Sentry: iki ardışık timeout, bestScore %75 ve %76 — eşik %65).
    static let gestureTimeout: TimeInterval = 15
    /// Oturum tavanının hareket bütçesinin ÜSTÜNE eklediği pay: her onayda 1sn ✅ animasyonu,
    /// yanlış harekette 1.5sn ceza, gülümseme gevşeme aşaması (≤5sn) ve yüz bulma süresi.
    static let sessionOverhead: TimeInterval = 20
    /// Yanlış hareket bütçesi. Kötüye kullanımın ASIL sınırı budur, saat değil: jest dizisi oturum
    /// boyunca sabit olduğundan sınırsız deneme, diziyi deneme-yanılmayla öğrenmeye izin verirdi.
    /// (Eskiden yanlış hareket sayısı SINIRSIZDI; tek fren 30sn'lik saatti.)
    static let maxWrongAttempts = 5

    enum FailureReason: String {
        /// Tek harekete ayrılan süre doldu (15sn). Kullanıcı komutu anlamadı ya da yapamadı.
        case gestureTimeout = "timeout_gesture"
        /// Oturum tavanı doldu (60sn). Genelde takılan/terk edilmiş oturum.
        case sessionTimeout = "timeout_session"
        case tooManyErrors  = "too_many_errors"
        case noSelfie       = "no_selfie"
        case matchFailed    = "match_failed"

        /// Ekranda ikisi de "süre doldu" olarak görünür — ayrım YALNIZ istatistik içindir.
        var isTimeout: Bool { self == .gestureTimeout || self == .sessionTimeout }
    }

    enum Phase: Equatable {
        case preparing
        case running
        case success
        case failure(FailureReason)
    }

    // MARK: Sunum (yalnız ana kuyruk)
    @Published var phase: Phase = .preparing
    @Published var instruction = ""
    @Published var subInstruction = ""
    @Published var stepText = ""
    /// Aktif hareketin kalan süre oranı (1 → tam, 0 → doldu). Ekranda RAKAM DEĞİL, incelen bir
    /// halka olarak gösterilir: rakam "yetişemeyeceksin" baskısı kuruyor ve kafa çevrikken zaten
    /// görünmüyor; halka "devam et" der.
    @Published var gestureProgress: Double = 1
    @Published var liveScorePercent = 0
    @Published var showScore = false   // chipEmbedding != nil
    @Published var checkmark = false
    @Published var wrongMove = false
    /// "Yanlış hareket: başınızı sağa çevirdiniz" — hangi hareketin yakalandığını söyler.
    @Published var wrongMoveDetail = ""
    @Published var qualityWarning: String?   // (b) ışık uyarısı — Android tvQualityWarning karşılığı
    @Published var debugEyeOpen = 0   // dev: canlı göz-açıklık % (blink kalibrasyonu)
    @Published var debugSmile = 0     // dev: canlı smile sinyali ×100 (smile kalibrasyonu)
    @Published private(set) var alignedSelfieJPEG: Data?

    /// Teşhis için dışarı verilebilecek son kare — başarıda da BAŞARISIZLIKTA da aynı kare:
    /// gönderilebilseydi sunucunun göreceği kare buydu. Reddedilen deneme, elimizdeki en
    /// değerli kare (eşleşme neden düştü sorusunu yalnız o yanıtlıyor), o yüzden `onFailure`
    /// ile dışarı verilir. Cihazdan KENDİLİĞİNDEN çıkmaz: kullanıcı geri bildirim kutusunda
    /// açıkça işaretlerse e-postaya ek olur. Demo yer tutucusu (boş Data) teşhis değildir.
    var diagnosticJPEG: Data? {
        guard let data = alignedSelfieJPEG, !data.isEmpty else { return nil }
        return data
    }
    @Published private(set) var antiSpoofCropJPEG: Data?

    /// Çip fotoğrafının MODELE GİREN hâli (hizalanmış 112×112 PNG). Ham DG2 değil: teşhis için
    /// gereken şey karşılaştırmanın girdisidir, belgenin kendisi değil. Buradan hiçbir yere GİTMEZ —
    /// yalnız geri bildirim kutusunda kullanıcı AYRI bir anahtarı açarsa e-postaya ek olur.
    @Published private(set) var alignedChipPNG: Data?

    /// Son denemenin skaler ölçüleri — geri bildirim e-postasının gövdesine eklenir.
    ///
    /// Neden gerekli: destek kutusuna bugüne kadar 112×112'lik bir kırpım gidiyordu ve YANINDA HİÇ
    /// SAYI YOKTU — "benzerlik yetersiz" diyen kullanıcının skorunu, kare parlaklığını, kafa açısını
    /// bilmeden sebebi tahmin etmekten başka şey yapılamıyordu. Buradaki her alan zaten hesaplanıyor
    /// ve yalnızca cihazdaki loga yazılıyordu.
    ///
    /// Hepsi SKALER: biyometrik veri değil, görüntü değil. Gizlilik maliyeti sıfır, teşhis değeri
    /// fotoğraftan yüksek — luma tek başına "arkadan ışık" hipotezini doğrular ya da çürütür.
    @Published private(set) var diagnosticsSummary: String = ""
    @Published private(set) var selfiePreview: UIImage?
    @Published private(set) var chipPreview: UIImage?
    private(set) var finalMatchScore: Float = 0

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()
    private let embedder = FaceEmbedder()
    private var ciContext: CIContext { FaceAnalyzer.sharedCIContext }   // tek paylaşılan context

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
    private var lastLuma: Float = -1   // en son ölçülen ortalama parlaklık (0-255)
    /// Sunucuya GİDEN kareye ait kalite ölçüleri. Pasif canlılık (anti-spoof) reddi tek bir skaler
    /// olarak geliyor ve görüntüyü SAKLAMIYORUZ (ZK); geriye dönük "neden sahte sanıldı" sorusunu
    /// ancak bu skalerler yanıtlayabilir — ışık, netlik, poz, yüzün kadrajdaki payı.
    private var savedFrameMetrics: String?
    private var lumaWarning: String?   // ışık uyarısı (her kare — video kuyruğu)
    private var blurWarning: String?   // netlik uyarısı (best-frame yakalamada — video kuyruğu)
    private let feedback = LivenessFeedback()
    private var wrongAttempts = 0

    /// Aktif hareketin ölçümü: komut EKRANA GELDİĞİ an (ms) ve o hareket için yapılan yanlış sayısı.
    ///
    /// Neden komut anından: "kullanıcı bu hareketi çözmeyi kaç saniyede başardı" sorusunun cevabı
    /// bu. Sayaç (`restartGestureClock`) yanlış hareketten ve onay animasyonundan sonra yeniden
    /// başlıyor, yani sayaçtan ölçmek "son denemesi kaç saniye sürdü"yü verirdi. Gülümsemedeki
    /// "önce yüzünüzü gevşetin" ara adımı da bilerek süreye dâhil: kullanıcı açısından o bekleme
    /// de gülümseme komutunun bir parçası.
    private var gestureStartedAtMs: TimeInterval = 0
    private var gestureWrongCount = 0
    /// Nötr bir yüz GÖRÜLDÜ mü? Gülümseme cezası ancak nötrden bir GEÇİŞ olarak yazılır, ve
    /// yazıldığı anda bu bayrak DÜŞER — yani sürekli gülümseyen (ya da öyle ölçülen) biri her
    /// karede hata yiyemez, yeniden nötr görülmeden ikinci ceza gelmez.
    ///
    /// Android'de bu bayrak vardı, iOS'ta HİÇ YOKTU: gerçek parite açığı buydu. Kullanıcının
    /// "hata mesajı kalkar kalkmaz aynısı tekrar geliyor, tüm haklarım doluyor" döngüsünü kıran
    /// da bu — challenge başına DEĞİL, gözlem başına sıfırlanır.
    private var smileGate = SmileEdgeGate()
    /// Gülümseme "yükselişi" ölçülebilir mi — kullanıcının nötr olduğu EN AZ BİR kare görüldü mü?
    /// Karar KARE bazlı verilir (Android paritesi): komut anındaki tek örnekleme kırılgandı ve
    /// gülümseyerek gelen kullanıcıya "yüzünüzü gevşetin" hiç gösterilmiyordu.
    private var smileArmed = false
    private var smileRelaxShown = false
    /// Nötre dönüş beklemesi için üst sınır (ms, epoch). Aşılırsa normal adıma geçilir — kullanıcı
    /// gevşeme aşamasında takılıp ASLA timeout yememeli (fail-open, eski davranış).
    private var smileArmDeadline: TimeInterval = 0
    static let smileRelaxTimeout: TimeInterval = 5
    private var lastSmileSignal: Float = 0
    /// Yüz izleme sürekliliği — kadrajdan çıkıp geri girme tespiti (ms, epoch).
    private var lastFaceTime: TimeInterval = 0
    /// Bir sonraki komutun sunulacağı an (ms, epoch; 0 = bekleyen yok).
    ///
    /// Eskiden bu iş `main.asyncAfter` → `camera.runOnVideoQueue` zinciriyle veriliyordu ve cihazda
    /// 40 SANİYE boyunca çalışmadı (Sentry 2026-08-25: "3/4" yazıldı, "4/4" ancak kamera durunca
    /// geldi) — üstelik aynı sürede kareler kesintisiz işleniyordu (en büyük boşluk 235 ms).
    /// Kuyruk sıçramasının neden geciktiğini açıklayamadım; bu yüzden ona GÜVENMİYORUM. Komut artık
    /// zaten çalıştığını ÖLÇTÜĞÜMÜZ kare döngüsünün içinde, zamanı gelince sunuluyor.
    private var pendingPresentAtMs: TimeInterval = 0
    /// Gözlenen kare aralığının üstel hareketli ortalaması (ms). İzleme boşluğu eşiği buna
    /// göreceli — sabit eşik, kare hızı düştüğünde jest mantığını aç bırakıyordu.
    private var frameIntervalMs: TimeInterval = 0
    private var warmupUntil: TimeInterval = 0
    static let trackingGapMs: TimeInterval = 400
    static let trackingWarmupMs: TimeInterval = 400

    /// Koşu başladıktan sonra "yüz yok" demeden önce beklenen süre — kamera ısınsın, kullanıcı
    /// telefonu yerleştirsin diye. Bu süre içinde uyarı verirsek her koşu bir azarla açılır.
    static let noFaceGraceMs: TimeInterval = 2000
    /// Yüzün kaç ms kayıp kalması uyarıyı hak eder. Baş çevirme sırasında dedektör kısa süre
    /// yüzü kaybedebiliyor; eşik bunun üstünde olmalı yoksa uyarı yanıp söner.
    static let noFaceWarnMs: TimeInterval = 1500
    /// Koşunun (video kuyruğunda) başladığı an — "yüz yok" uyarısının gecikmesi buradan ölçülür.
    private var runStartedAtMs: TimeInterval = 0
    /// "Yüzünüz çerçevede değil" uyarısı (video kuyruğu).
    private var faceMissingWarning: String?
    /// Kafa, yeni challenge sunulduktan sonra nötre döndü mü? Dönmeden yanlış-hareket SAYILMAZ:
    /// aksi halde FaceRight→FaceLeft dizisinde kullanıcı, kendi az önceki DOĞRU hareketi yüzünden
    /// hata yiyordu.
    private var poseSettled = false

    /// Hareket süresi azaldığında verilen tek seferlik dürtme — her harekette sıfırlanır.
    static let lowTimeFraction = 0.27   // 15sn'nin son ~4 saniyesi
    private var nudged = false

    /// Oturum tavanı — hareket bütçesinden TÜRETİLİR, sabit değildir.
    ///
    /// Sabit 60sn yanlıştı: 5 hareket × 15sn = 75sn'lik hareket bütçesini karşılamıyordu, yani
    /// "her harekete 15 saniye" sözü 4. harekette sessizce bozuluyordu. Hareket süresi ya da
    /// challenge sayısı değişirse tavan kendiliğinden uyar; ikisi bir daha çelişemez.
    let effectiveSessionTimeout: TimeInterval

    /// Tavanın formülü — örnek GEREKTİRMEZ.
    ///
    /// Ayrı bir statik fonksiyon olmasının sebebi test edilebilirlik: bunu bir `LivenessViewModel`
    /// üzerinden doğrulamak, sırf bir aritmetik sabit için `FaceEmbedder`'ı (dolayısıyla MobileFaceNet
    /// CoreML modelini) yüklemek demekti. `testSessionCapCoversTheGestureBudget` üç VM kuruyordu ve
    /// simülatörde asılıp test sürecini öldürüyordu — CI'da 497 saniye, 33 testten 16'sı.
    static func sessionTimeout(challengeCount: Int) -> TimeInterval {
        // Dizi 5'e tamamlanıyor (resetLogicState) → tavan da en az 5 hareketi karşılamalı.
        gestureTimeout * Double(max(challengeCount, 5)) + sessionOverhead
    }

    private var timer: Timer?
    private var sessionStartedAt: Date?
    private var gestureStartedAt: Date?

    /// Akışın huni anahtarı — hareket olayları koşu SIRASINDA doğuyor, yani sonuna kadar
    /// bekletilip RegisterViewModel'e bırakılamıyor (canlılık hatasında öyle yapılıyor).
    /// Android'de karşılığı `LivenessActivity`'nin `flow_nonce` intent extra'sı.
    private let flowNonce: String?

    init(challenges: [Int], chipPhotoData: Data?, isDemo: Bool = false, flowNonce: String? = nil) {
        let input = challenges.map(LivenessAction.fromInt).filter { $0 != .none }
        self.effectiveSessionTimeout = Self.sessionTimeout(challengeCount: input.count)
        self.challengesInput = challenges.map(LivenessAction.fromInt).filter { $0 != .none }
        self.chipPhotoData = chipPhotoData
        self.isDemo = isDemo
        self.flowNonce = flowNonce
    }

    // MARK: - Yaşam döngüsü (ana kuyruk)

    func start() {
        showScore = chipPhotoData != nil
        if let data = chipPhotoData, let ui = UIImage(data: data) { chipPreview = ui }

        camera.onFrame = { [weak self] buffer, _ in
            self?.updateQualityWarning(for: buffer)   // (b) ışık uyarısı — her kare (yüz olmasa da)
        }
        // ML Kit `VisionImage`'ı CVPixelBuffer kabul etmiyor → yüz analizi ayrı kanaldan besleniyor.
        // Aynı kare, aynı video kuyruğu; yalnız taşıyıcı tip farklı.
        camera.onSampleBuffer = { [weak self] sample, orientation in
            self?.analyzer.process(sample, orientation: orientation)
        }
        // Yüz bulunamayan karelerde de vadesi gelmiş komut sunulmalı: kullanıcı jestten sonra
        // kadraj dışına çıkarsa akış aksi halde orada takılırdı.
        analyzer.onNoFace = { [weak self] in self?.presentPendingChallengeIfDue() }
        analyzer.onFace = { [weak self] frame in
            self?.handleFace(frame) // video kuyruğu
        }
        beginRun()
    }

    func stop() {
        invalidateTimer()
        camera.stop()
        feedback.deactivate()
    }

    func retry() {
        // İz bırakıyoruz çünkü bir kullanıcı "Tekrar Dene"nin MRZ'ye döndürdüğünü bildirdi, oysa
        // bu yol yalnız `beginRun()` çağırıyor — MRZ'ye götüren tek yer `onLivenessCancel`.
        // Bir sonraki raporda hangi butonun basıldığını tahmin etmek yerine kayıttan okuyacağız.
        Log.info("Liveness: 'Tekrar Dene' → koşu yeniden başlatılıyor", category: .liveness)
        beginRun()
    }

    private func beginRun() {
        feedback.activate()   // sessiz moddayken de duyulmalı (Android medya akışıyla parite)
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

    private var antiSpoofCropJPEGLogic: Data?  // video kuyruğu; main'e finalizeSuccessAttempt'te taşınır

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
        antiSpoofCropJPEGLogic = nil
        lastActionTime = 0
        lastCaptureTime = 0
        wrongAttempts = 0
        smileArmed = false
        smileRelaxShown = false
        smileArmDeadline = 0
        lastSmileSignal = 0
        savedFrameMetrics = nil
        lastFaceTime = 0
        warmupUntil = 0
        frameIntervalMs = 0
        pendingPresentAtMs = 0
        runStartedAtMs = Date().timeIntervalSince1970 * 1000
        faceMissingWarning = nil
        poseSettled = false
        smileGate.reset()   // yeni oturum → nötr yüz henüz görülmedi
        analyzer.resetDiagnostics()
    }

    private func prepareChipEmbeddingIfNeeded() {
        guard chipEmbedding == nil, let data = chipPhotoData, let cg = UIImage(data: data)?.cgImage else { return }
        let eyes = Self.detectEyes(in: cg)
        if let aligned = FaceAligner.alignedImage(from: cg, leftEye: eyes.left, rightEye: eyes.right) {
            chipEmbedding = embedder.embedding(from: aligned)
            // AYNI hizalanmış kareyi teşhis için de saklıyoruz — eşleştirme yolu değişmez,
            // yalnızca zaten üretilmiş olan görüntü bir kez daha kodlanır.
            let png = UIImage(cgImage: aligned).pngData()
            DispatchQueue.main.async { [weak self] in self?.alignedChipPNG = png }
        }
        let method = eyes.left != nil ? "ALIGNED" : "FALLBACK"
        Log.info("Liveness chip embedding (\(method)) size=\(chipEmbedding?.count ?? 0)", category: .liveness)
    }

    /// index'i (video kuyruğu) okur ve UI'yi ana kuyrukta sunar. index taşmışsa başarı değerlendir.
    private func presentChallengeForIndex() {
        Log.info("Liveness ilerletme 4/4: komut hazırlanıyor, index=\(index)/\(challenges.count)",
                 category: .liveness)
        poseSettled = false
        if index >= challenges.count {
            finalizeSuccessAttempt()
            return
        }
        let action = challenges[index]
        let step = "\(index + 1)/\(challenges.count)"
        // Gülümseme HER ZAMAN bir GEÇİŞ olarak ölçülür; "nötr görüldü mü" kararı processAction'da
        // kare kare verilir (bkz. smileArmed).
        smileArmed = false
        smileRelaxShown = false
        smileArmDeadline = Date().timeIntervalSince1970 * 1000 + Self.smileRelaxTimeout * 1000
        // Hareket ölçümü BURADAN başlar — presentChallenge'da DEĞİL: o ana kuyruğa asenkron
        // dispatch ediliyor, yani ölçüm video kuyruğu ilerledikten sonra düşebilirdi. Buradaki
        // smileArmed/smileArmDeadline ile aynı cinsten, hareket başına logic durumu.
        gestureStartedAtMs = Date().timeIntervalSince1970 * 1000
        gestureWrongCount = 0
        DispatchQueue.main.async { [weak self] in
            self?.presentChallenge(action: action, step: step)
        }
    }

    /// Vadesi gelmiş bir komut varsa sunar. Kare döngüsünden çağrılır — yüz bulunsun bulunmasın.
    private func presentPendingChallengeIfDue() {
        guard pendingPresentAtMs > 0 else { return }
        let now = Date().timeIntervalSince1970 * 1000
        guard now >= pendingPresentAtMs else { return }
        pendingPresentAtMs = 0
        presentChallengeForIndex()
    }

    private func handleFace(_ frame: FaceAnalyzer.Frame) {
        presentPendingChallengeIfDue()
        let quality = LivenessGestureDetector.qualityScore(frame.signals, imageSize: frame.imageSize)
        captureFrame(frame, quality: quality)
        processAction(frame.signals)
    }

    private func processAction(_ signals: FaceSignals) {
        guard !isDemo, index < challenges.count else { return }
        let now = Date().timeIntervalSince1970 * 1000

        // Canlı kalibrasyon göstergeleri (dev) — her karede. Artık ikisi de GERÇEK olasılık yüzdesi.
        let eyeOpen = min(signals.leftEyeOpen, signals.rightEyeOpen)
        let eyePct = Int(eyeOpen * 100)
        let smilePct = Int(signals.smile * 100)
        DispatchQueue.main.async { [weak self] in
            self?.debugEyeOpen = eyePct
            self?.debugSmile = smilePct
        }

        // Yüz izleme koptu mu? Kadrajdan çıkıp geri girildiğinde ilk kareler bozuk gelir. Android'de
        // bu koruma YOK; iOS'ta kalıyor (parite = birleşim: ileri tarafı geri çekme).
        // Eşik MUTLAK olamaz. 400 ms sabiti, kareler 30 fps geldiğinde doğruydu; ML Kit'e geçince
        // kare aralığı ~600 ms'ye çıktı ve koşul HER karede doğru olmaya başladı: `warmupUntil`
        // sürekli 400 ms ileri itildi, guard bir daha asla geçilemedi ve jest tespiti ilk kareden
        // sonra tamamen öldü ("ilk hareket kabul edildi, sonrasında hiçbir şey algılanmıyor",
        // cihaz kaydı 2026-08-25). Küçültme kare hızını geri getirdi, ama yavaş bir cihazda aynı
        // tuzak yeniden kurulurdu — bu yüzden eşik artık GÖZLENEN kare aralığına göreceli.
        //
        // "Kopma" = normal ritmin belirgin dışına çıkan boşluk. Mutlak taban korunuyor: kareler
        // hızlıyken 2.5 kat, gerçek bir yüz kaybını temsil edecek kadar uzun değildir.
        if lastFaceTime > 0 {
            let gap = now - lastFaceTime
            let expected = frameIntervalMs > 0 ? frameIntervalMs : gap
            if gap > max(Self.trackingGapMs, expected * 2.5) {
                warmupUntil = now + Self.trackingWarmupMs
            }
            // EMA karşılaştırmadan SONRA güncellenir: aksi halde tek bir uzun boşluk beklentiyi
            // kendi seviyesine çeker ve bir sonraki gerçek kopmayı gizler.
            frameIntervalMs = frameIntervalMs > 0 ? frameIntervalMs * 0.8 + gap * 0.2 : gap
        }
        lastFaceTime = now

        // Sınıflandırma gelmediyse bu kare ÖLÇÜM DEĞİLDİR (bkz. FaceSignals.landmarksOK).
        guard signals.landmarksOK, now >= warmupUntil else { return }

        lastSmileSignal = signals.smile

        // Kafa nötre döndüyse yanlış-hareket sayımı açılır (bkz. poseSettled).
        if !poseSettled, abs(signals.yaw) < LivenessGestureDetector.yawThreshold { poseSettled = true }

        // Nötr yüz görüldü → bundan sonraki yükseliş YENİ bir gülümsemedir (kenar tespiti).
        smileGate.observe(lastSmileSignal)

        let target = challenges[index]

        // Gülümseme "arming": nötr bir kare görülmeden gülümseme KABUL EDİLMEZ. Throttle'dan önce
        // çalışır ki geçiş akıcı olsun. Kullanıcı komut anında gülümsüyorsa talimat "yüzünüzü
        // gevşetin"e döner; nötre inince asıl komut geri gelir ve sayaç tam süreyle yeniden başlar.
        //
        // Bu ekranın yüz ASIKKEN çıkması, Vision döneminde göreceli baseline'ın bozulmasından
        // geliyordu; karar artık mutlak bir olasılık eşiğine (0.4) dayanıyor.
        if target == .smile, !smileArmed {
            let gaveUp = now >= smileArmDeadline
            if LivenessGestureDetector.isSmileNeutral(lastSmileSignal) || gaveUp {
                smileArmed = true
                if smileRelaxShown {
                    let step = "\(index + 1)/\(challenges.count)"
                    DispatchQueue.main.async { [weak self] in
                        self?.presentChallenge(action: .smile, step: step)
                    }
                }
            } else if !smileRelaxShown {
                smileRelaxShown = true
                DispatchQueue.main.async { [weak self] in
                    self?.showSmileRelaxPrompt()
                }
            }
            return
        }

        // İlerleme throttle'dan SONRA (önceki jestin yeni challenge'a sızmasını önler).
        guard now - lastActionTime >= 2000 else { return }

        guard let detected = LivenessGestureDetector.detect(signals) else { return }

        if detected == target {
            advanceOnSuccess(now: now)
            return
        }

        // Hedef dışı KASITLI jest → hata bütçesinden düşer. Kafa henüz nötre dönmediyse sayılmaz.
        //
        // Göz kırpma bir REFLEKSTİR — asla sayılmaz (detect() zaten yalnız hedefteyken blink döndürse
        // bile buraya blink düşmez: hedef değilse aşağıdaki iki koşulun hiçbirine girmez).
        // Gülümseme İRADİDİR ve sayılır: yalnız kafa dönüşünü saymak bütçeyi işlevsiz bırakıyordu,
        // çünkü ekranı okuyamayan bir deneme-yanılma düzeneği blink ve smile'ı bedavaya eleyip
        // yalnız kafa dönüşü pozisyonlarında risk alırdı.
        //
        // AMA yalnızca NÖTRDEN YÜKSELİŞ sayılır (`smileGate`): mutlak eşiğin üstünde DURAN
        // biri her karede hata yiyemez, ve bir ceza yazıldıktan sonra yeniden nötr görülmeden
        // ikincisi gelmez. Kullanıcının yaşadığı "mesaj kalkar kalkmaz aynısı" döngüsünü bu keser.
        guard poseSettled else { return }
        if detected == .faceLeft || detected == .faceRight {
            handleWrongGesture(now: now, detected: detected)
        } else if detected == .smile, smileGate.consumeIfArmed() {
            handleWrongGesture(now: now, detected: .smile)
        }
    }

    /// Hareket kabul → sıradaki komut.
    ///
    /// ⚠️ Bu geçiş DÖRT kuyruk sıçraması: video → main (tik) → main+1sn → video (hazırlık) →
    /// main (ekran). 2026-08-25 cihaz testinde tik ekranda ASILI kaldı: adım ilerlemedi, sayaç
    /// saymayı sürdürdü, kafa çevrilince yanlış-hareket sesi geldi ama yazı çıkmadı — çünkü tik
    /// `instructionBlock` sırasında en üstte ve uyarıyı da örtüyor. Yani `index` arttı fakat
    /// `presentChallenge` hiç koşmadı: zincir ortada koptu.
    ///
    /// Kopma noktası kodu okuyarak bulunamadı (dört halkanın dördü de tek başına doğru), o
    /// yüzden her sıçrama iz bırakıyor. Bir sonraki raporda hangi satırın YAZILMADIĞINA bakıp
    /// yeri tahmin etmeden bulacağız.
    private func advanceOnSuccess(now: TimeInterval) {
        lastActionTime = now
        reportGesture(timedOut: false)
        index += 1
        Log.info("Liveness ilerletme 1/4: hareket kabul, index=\(index)", category: .liveness)
        feedback.play(.stepOk)   // kafa çevrikken ekranı GÖREMİYOR — onayı ses/haptic taşır
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Sayaç ONAY animasyonu başlarken sıfırlanır: aksi halde son saniyede yapılan DOĞRU bir
            // hareketin ardından, bir sonraki talimat ekrana gelmeden timeout tetikleniyordu.
            self.restartGestureClock()
            self.checkmark = true
            Log.info("Liveness ilerletme 2/4: tik gösterildi", category: .liveness)
        }
        // 1 sn ✅ animasyonundan sonra sunulacak (kare döngüsü tetikler, kuyruk sıçraması YOK).
        pendingPresentAtMs = now + 1000
    }

    /// Yanlış hareket: hata bütçesinden düşer ve AYNI hareket yeniden sorulur.
    ///
    /// Eskiden `index = 0` ile diziye baştan başlanıyordu. Bu hem meşru kullanıcıyı cezalandırıyordu
    /// (tek yanlış dönüş = tüm hareketler yeniden) hem de saldırgana yarıyordu: dizi sabit olduğu
    /// için öğrenilen önek hızlıca tekrar oynatılıp yalnız bir sonraki adım deneniyordu. Artık sınırı
    /// saat değil, sayılabilir bir bütçe koyuyor.
    private func handleWrongGesture(now: TimeInterval, detected: LivenessAction) {
        lastActionTime = now
        gestureWrongCount += 1
        wrongAttempts += 1
        poseSettled = false
        feedback.play(.wrong)
        let exhausted = wrongAttempts >= Self.maxWrongAttempts
        // Kullanıcı NE yaptığını görmeli; yalnız "yanlış hareket" demek "ben ne yaptım ki?" bırakıyor.
        let didKey: String
        switch detected {
        case .faceLeft:  didKey = "liveness_did_face_left"
        case .faceRight: didKey = "liveness_did_face_right"
        default:         didKey = "liveness_did_smile"
        }
        if exhausted {
            finalizeFailure(.tooManyErrors)   // zaten video kuyruğundayız — sıçramaya gerek yok
            return
        }
        // Ceza animasyonundan sonra AYNI hareket yeniden sorulur; tetikleyici kare döngüsü.
        pendingPresentAtMs = now + 1500
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restartGestureClock()   // ceza animasyonu sırasında sayaç dolmasın
            self.wrongMoveDetail = L.t("liveness_wrong_move_detail", L.t(didKey))
            self.wrongMove = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.wrongMove = false }
        }
    }

    /// Best-frame yakalama (Android captureFrame). 400ms throttle.
    private func captureFrame(_ frame: FaceAnalyzer.Frame, quality: Float) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastCaptureTime >= 400 else { return }
        lastCaptureTime = now

        // Aşamalar ölçülüyor: 2026-08-25'te uygulama video kuyruğunda 77 saniye tamamen durdu ve
        // hangi çağrının tıkadığını ancak süre kaydı söyleyebilir (cihazda debugger yok).
        guard let fullCG = analyzer.timing.measure("tamKare", { cgImage(from: frame.pixelBuffer) }) else { return }
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
        // Bulanık/kirli lens veya hareket bulanıklığında düşük çıkar (Android computeSharpness paritesi).
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
            // embedding'i bozabilir, dosya zaten ~20-40 KB. (Değişken adı geçmişten "JPEG" kaldı.)
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
        // Başarıda da üretilir: sunucudaki anti-spoof reddi bu adımdan SONRA geliyor, yani
        // "canlılık geçti ama kayıt düştü" vakasında elimizdeki tek kare ölçüsü bu.
        let summary = makeDiagnosticsSummary(reason: nil)
        let hasSelfie = selfieJPEG != nil
        let verified = isIdentityVerified
        let hasChip = chipEmbedding != nil
        let score = bestMatchScore
        let jpeg = selfieJPEG
        let cropJPEG = antiSpoofCropJPEGLogic

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidateTimer()
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
            // Kalite ölçüleri BAŞARIDA da yazılır: sunucudaki anti-spoof reddi buradan SONRA gelir,
            // yani "canlılık geçti ama sunucu sahte dedi" vakasında elimizdeki tek ipucu bu satır.
            Log.info("Liveness başarı: score=\(Int(score * 100))% verified=\(verified) " +
                     "[\(metrics ?? "kare ölçüsü yok")]", category: .liveness)
            self.feedback.play(.done)
            self.phase = .success
        }
    }

    /// Aktif hareketin sonucunu huniye bildirir: hangi hareket, kaç ms sürdü, kaç yanlıştan sonra.
    ///
    /// Neden bu ayrıntı toplanıyor da kare akışı toplanmıyor: bu satırlar AKIŞLA büyür, kareyle
    /// değil — jest kümesi dört elemanlı ve sunucu `(flow_id, step)` benzersizliğiyle her hareketi
    /// akış başına bir kez sayıyor. Her karenin sinyalini göndermek ise kareyle büyürdü ve hiçbir
    /// kararı değiştirmezdi.
    private func reportGesture(timedOut: Bool) {
        guard !isDemo, gestureStartedAtMs > 0 else { return }
        guard index < challenges.count else { return }
        let step: FlowTelemetry.Step
        switch challenges[index] {
        case .faceLeft:  step = .gestureLeft
        case .faceRight: step = .gestureRight
        case .smile:     step = .gestureSmile
        case .blink:     step = .gestureBlink
        // Enclave hiç .none göndermez; gelse de raporlanacak bir hareket yok.
        case .none:      return
        }
        let duration = Int(Date().timeIntervalSince1970 * 1000 - gestureStartedAtMs)
        let wrongs = gestureWrongCount
        guard let nonce = flowNonce else { return }
        // Aynı hareket iki kez raporlanmasın (sunucu da yutar, ama gereksiz istek atmayalım).
        gestureStartedAtMs = 0
        Task { await FlowTelemetry.shared.gestureResolved(step, durationMs: duration,
                                                          wrongCount: wrongs, timedOut: timedOut,
                                                          nonce: nonce) }
    }

    /// Teşhis özetini üretir. ⚠️ VİDEO KUYRUĞUNDAN çağrılır: okuduğu alanların (skor, index,
    /// wrongAttempts, savedFrameMetrics) tamamı logic-state'tir ve ana kuyruktan okunması veri
    /// yarışı olurdu — dosyanın geri kalanındaki desen de bu (değeri burada yakala, main'e taşı).
    private func makeDiagnosticsSummary(reason: FailureReason?) -> String {
        let chip: String
        if chipEmbedding != nil { chip = "var" }
        else if chipPhotoData == nil { chip = "yok" }
        else { chip = "çözülemedi" }
        var line = "Canlılık / Liveness: skor=%\(Int(bestMatchScore * 100))"
            + " (cihaz eşiği %\(Int(Self.matchThreshold * 100)))"
            + " adım=\(index)/\(challenges.count)"
            + " yanlış=\(wrongAttempts)"
            + " çip=\(chip)"
        if let reason { line += " sebep=\(reason.rawValue)" }
        return line + "\nKare / Frame: " + (savedFrameMetrics ?? "kare kaydedilmedi")
    }

    /// Video kuyruğundan çağrılır (logic-state okur), sonucu ana kuyruğa taşır.
    private func finalizeFailure(_ reason: FailureReason) {
        let metrics = savedFrameMetrics
        let score = bestMatchScore
        let wrongs = wrongAttempts
        let summary = makeDiagnosticsSummary(reason: reason)
        // Sayaçlar video kuyruğunda yazılıyor → dizeyi BURADA yakala, main'de değil.
        // Parlaklık da eklenir: ML Kit hiç yüz bulamadığında ayırt edilmesi gereken ilk şey
        // görüntünün BOŞ olup olmadığı, ve ekrandaki uyarı bunu söylemiyor — "yüzünüz çerçevede
        // değil" uyarısı ışık uyarısının ÖNÜNDE gösteriliyor, yani karanlık kareyi maskeliyor.
        let diag = analyzer.diagnostics + " luma=\(Int(lastLuma))"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.phase == .running else { return }   // çift tetiklenmeye karşı
            self.invalidateTimer()
            self.camera.stop()
            self.finalMatchScore = score
            self.diagnosticsSummary = summary
            Log.warning("Liveness başarısız (\(reason)) — bestScore=\(Int(score * 100))% yanlış=\(wrongs) " +
                        "[\(metrics ?? "kare ölçüsü yok")] \(diag)", category: .liveness)
            self.phase = .failure(reason)
        }
    }

    // MARK: - Sunum (ana kuyruk)

    /// Kullanıcı komut gelmeden gülümsüyor → önce nötre dönmesi istenir (sayaç DEVAM eder;
    /// asıl komut geri geldiğinde `presentChallenge` süreyi zaten sıfırlar).
    private func showSmileRelaxPrompt() {
        instruction = L.t("liveness_face_smile_relax")
        subInstruction = L.t("liveness_face_smile_relax_hint")
    }

    private func presentChallenge(action: LivenessAction, step: String) {
        Log.info("Liveness komut ekranda: \(step) \(action)", category: .liveness)
        stepText = step
        checkmark = false
        wrongMove = false
        wrongMoveDetail = ""
        restartGestureClock()
        switch action {
        case .faceLeft:  instruction = L.t("liveness_face_left")
        case .faceRight: instruction = L.t("liveness_face_right")
        case .blink:     instruction = L.t("liveness_face_blink")
        case .smile:     instruction = L.t("liveness_face_smile")
        case .none:      instruction = "—"
        }
        subInstruction = L.t("liveness_perform_action")
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
            feedback.play(.done)
            phase = .success
            return
        }
        presentChallenge(action: demoList[step], step: "\(step + 1)/\(demoList.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .running else { return }
            self.feedback.play(.stepOk)   // demo gerçek akışı temsil etmeli (aynı ses/haptic)
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
        timer?.invalidate()
        let now = Date()
        sessionStartedAt = now
        gestureStartedAt = now
        gestureProgress = 1
        // 0.1sn tick → halka akıcı erisin (saniyelik rakam yok).
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self,
                  let gestureStart = self.gestureStartedAt,
                  let sessionStart = self.sessionStartedAt else { return }
            let gestureLeft = Self.gestureTimeout - Date().timeIntervalSince(gestureStart)
            self.gestureProgress = max(0, min(1, gestureLeft / Self.gestureTimeout))
            if !self.nudged, self.gestureProgress <= Self.lowTimeFraction, self.gestureProgress > 0 {
                self.nudged = true
                self.feedback.play(.nudge)
            }
            let sessionOver = Date().timeIntervalSince(sessionStart) >= self.effectiveSessionTimeout
            guard gestureLeft <= 0 || sessionOver else { return }
            self.timer?.invalidate()
            self.timer = nil
            // Hangi sayacın dolduğu istatistikte AYRI görünmeli: tek hareket süresi dolması komutun
            // anlaşılmadığını, oturum tavanı ise akışın terk edildiğini gösterir — farklı düzeltmeler.
            // Süresi dolan hareket HANGİSİYDİ — huninin "canlılıkta kaybettik"ten sonra
            // söyleyebildiği tek ayrıntı bu. Akış özetinden ÖNCE gönderilir.
            self.reportGesture(timedOut: true)
            let reason: FailureReason = sessionOver ? .sessionTimeout : .gestureTimeout
            // Video kuyruğuna SIÇRAMADAN bitir: "Time's Up" ekranı o sıçrama yüzünden 25 saniye
            // gecikmişti (Sentry 2026-08-25). `finalizeFailure` yalnız logic durumunu OKUR ve
            // sunumu zaten ana kuyruğa taşır; okunan alanlar tek kelimelik ve yarış riski,
            // kullanıcıyı donmuş bir ekranda bırakmaktan çok daha küçük bir bedel.
            self.finalizeFailure(reason)
        }
    }

    /// Yeni hareket sunuldu → hareket sayacı sıfırlanır (ana kuyruk). İlerleyen kullanıcı böylece
    /// asla zamana yenilmez; oturum tavanı (`effectiveSessionTimeout`) yerinde kalır.
    private func restartGestureClock() {
        gestureStartedAt = Date()
        gestureProgress = 1
        nudged = false
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

    /// MiniFASNetV2 için 2.7x geniş 80x80 JPEG crop (Android LivenessActivity:666 port).
    /// box: captureFrame'deki piksel-koordinatlı yüz kutusu (captureFrame'den doğrudan gelir).
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

    // MARK: - (b) Ortam kalitesi (ışık) — Android LivenessAnalyzer.averageLuma karşılığı

    /// Her karede ortalama parlaklığı ölçer ve karanlık/aşırı-parlak uyarısını (ana kuyrukta) günceller.
    /// Video kuyruğunda çağrılır (Android onFrameLuma ile aynı disiplin).
    private func updateQualityWarning(for pixelBuffer: CVPixelBuffer) {
        let luma = Self.averageLuma(pixelBuffer)
        lastLuma = luma

        // "Yüzünüz çerçevede değil" — ışık/netlik uyarılarının ÖNÜNDE gelir.
        //
        // Yüz bulunamayan kare sessizce atılıyordu: kullanıcı 15 saniye boyunca hiçbir geri
        // bildirim almadan bekliyor, sonunda "Süre doldu — hareket tamamlanmadı" yiyordu.
        //
        // Yüzün neden bulunamadığı DEĞİŞKEN (kadraj, ışık, dedektörün kendi arızası) ve buradan
        // bilinemez. Mesele sebep değil, sessizlik: uygulama kare gelmediğini zaten biliyorken
        // susup faturayı kullanıcıya kesiyordu.
        //
        // Bu satırlar `handleFace` ile AYNI kuyrukta (video) koşar, o yüzden `lastFaceTime`
        // burada kilitsiz okunabilir.
        let now = Date().timeIntervalSince1970 * 1000
        let runningLongEnough = runStartedAtMs > 0 && now - runStartedAtMs > Self.noFaceGraceMs
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

    /// Işık (öncelikli) + netlik uyarısını tek label'da birleştirir (Android `publishQualityWarning`).
    /// Video kuyruğunda çağrılır; `@Published` güncellemesi ana kuyruğa marshalled edilir.
    private func publishWarning() {
        // Sıra önemli: yüz kadrajda değilken "ortam karanlık" demek yanlış hedefi gösterir.
        let w = faceMissingWarning ?? lumaWarning ?? blurWarning
        DispatchQueue.main.async { [weak self] in
            guard let self, self.qualityWarning != w else { return }
            self.qualityWarning = w
        }
    }

    // MARK: - Netlik (blur) ölçümü — Android computeSharpness karşılığı

    /// 112×112 yüz CGImage'ında ileri-fark gradyan enerjisi (Brenner benzeri). Yüksek = net.
    /// Eşikler `blurWarnThreshold` / `sharpQualityRef` ile aynı; sabit 112 boyut → eşik anlamlı
    /// (yine de cihazda ince ayar gerekebilir).
    static let blurWarnThreshold: Float = 45
    static let sharpQualityRef: Float = 250   // bu enerjide tam +15 kalite bonusu

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
