import ImageIO
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import UIKit
import MLKitFaceDetection
import MLKitVision

/// Yüz tespiti — Android `util/LivenessAnalyzer` ile **AYNI kütüphane** (Google ML Kit Face).
///
/// Eskiden Apple Vision kullanıyordu. Vision `smilingProbability` / `eyeOpenProbability`
/// VERMEDİĞİ için bu olasılıkları göz ve ağız landmark geometrisinden TÜRETİYORDUK; iOS'un
/// yaşadığı her liveness hatası o türetimden çıktı (blink hiç tetiklenmemesi, gülümsemenin
/// erişilemez olması, gülümseme↔blink çapraz kirlenmesi, ve nötr bir yüzü gülümseme sayan
/// baseline zehirlenmesi). Android aynı sorunların hiçbirini yaşamadı çünkü ML Kit'in
/// EĞİTİLMİŞ sınıflandırıcı çıktısını doğrudan okuyordu. Artık iOS de öyle okuyor.
///
/// ⚠️ `onFace` VİDEO KUYRUĞUNDA, senkron, canlı `pixelBuffer` ile çağrılır → tüketici yakalama
/// işini (crop/align/embed) burada yapabilir; pixelBuffer kuyruklar arası tutulmamalı.
/// Koordinatlar TOP-LEFT piksel uzayında (CGImage/UIImage ile uyumlu → FaceAligner doğrudan kullanır).
final class FaceAnalyzer {

    struct Frame {
        let signals: FaceSignals
        let pixelBuffer: CVPixelBuffer
        let imageSize: CGSize
        let orientation: CGImagePropertyOrientation
    }

    var onFace: ((Frame) -> Void)?
    var onNoFace: (() -> Void)?

    /// Ön kamera aynası telafisi. ML Kit'in `headEulerAngleY`'si "görüntünün sağına dönük yüz =
    /// pozitif" tanımlı ve `LivenessGestureDetector` bunu Android'in kuralıyla okuyor
    /// (pozitif = FaceLeft). Ama Android analiz karesini AYNALAMAZ, biz aynalıyoruz
    /// (`CameraController.isVideoMirrored = true`, selfie hissi için) — ayna yaw'ın işaretini
    /// çevirir. Bu yüzden -1 ile geri çevriliyor; Vision döneminde de aynı sebeple -1'di.
    ///
    /// Cihazda sol/sağ ters çıkarsa düzeltme YALNIZ bu değerdir: +1 yap.
    var yawSign: Float = -1

    /// Android `LivenessAnalyzer` ile birebir aynı ayarlar. `classificationMode = .all` OLMADAN
    /// `smilingProbability` / `eyeOpenProbability` HİÇ gelmez — bu satır bu dosyanın varlık sebebi.
    ///
    /// `lazy`: dedektörü kurmak model yüklemek demek ve `FaceAnalyzer`, `LivenessViewModel`'ın
    /// depolanmış bir alanı — yani VM'i sırf bir sabiti okumak için örnekleyen bir birim testi bile
    /// bunun bedelini ödüyordu. `LivenessLogicTests.testSessionCapCoversTheGestureBudget` üç VM
    /// kurup CI'da zaman aşımına girecek kadar (426 sn) yavaşlamıştı. İlk kare gelene dek kurulmaz.
    ///
    /// İplik: yalnız `process` içinden, yalnız kamera video kuyruğundan erişilir (`lazy` Swift'te
    /// iplik-güvenli DEĞİL; buradaki güvence tek kuyruğa hapsolmuş olması).
    private lazy var detector: FaceDetector = {
        let options = FaceDetectorOptions()
        options.performanceMode = .accurate
        options.landmarkMode = .all          // göz merkezleri → FaceAligner
        options.classificationMode = .all    // gülümseme + göz açıklık olasılıkları
        options.contourMode = .none          // kontur pahalı ve kullanılmıyor
        // Android `enableTracking()` çağırıyor; burada BİLİNÇLİ olarak yok. Tracking yalnız
        // kareler arası yüz KİMLİĞİ (trackingID) üretir ve biz onu hiçbir yerde okumuyoruz —
        // her karede en büyük yüzü seçiyoruz. Parite sinyallerde, kimlik atamada değil.
        return FaceDetector.faceDetector(options: options)
    }()

    private var isAnalyzing = false
    /// TEK paylaşılan context. Her `CIContext` kendi GPU önbelleğini tutuyor; iki ayrı örnek
    /// tutmak (analiz için bir, kare yakalama için bir) bellek baskısını gereksiz yere ikiye
    /// katlıyordu ve bu uygulamanın geçmişinde RAM kaynaklı watchdog sonlandırması var.
    static let sharedCIContext = CIContext()
    private var ciContext: CIContext { Self.sharedCIContext }
    /// Aşama süreleri — `LivenessViewModel` de kendi aşamalarını buraya kaydeder, böylece tek
    /// bir özet satırı video kuyruğunun TAMAMINI kapsar.
    let timing = StageTimer()

    /// ML Kit'e verilen görüntünün azami genişliği.
    ///
    /// 1080x1920'yi her karede CGImage'a çevirip `.accurate` dedektöre vermek cihazda kare hızını
    /// **1,66 fps'e** düşürdü (158 kare / ~95 sn). Bu yalnız yavaşlık değil, DOĞRULUK sorunu:
    /// `LivenessViewModel` 400 ms'lik izleme boşluğu ve 2 sn'lik throttle gibi eşiklerle çalışıyor
    /// ve kareler 600 ms arayla gelince jest mantığı kendi kendini aç bırakıyor.
    ///
    /// Yüz tespiti için 480 piksel fazlasıyla yeterli: bu genişlikte bile selfie'deki yüz ~200 px
    /// çıkıyor, ML Kit'in `minFaceSize` (genişliğin %10'u = 48 px) tabanının çok üstünde.
    /// Koordinatlar tam çözünürlüğe GERİ ÖLÇEKLENİR → `FaceSignals` ve aşağısı hiç değişmez.
    private static let detectionMaxWidth: CGFloat = 480

    // MARK: Teşhis
    //
    // Bu sayaçlar geçici DEĞİL, kalıcı: "hiçbir hareketim algılanmadı" şikâyeti geldiğinde
    // ayırt etmemiz gereken üç durum var ve üçü de ekranda AYNI görünüyor — kare hiç gelmiyor,
    // kare geliyor ama ML Kit yüz bulmuyor, yüz bulunuyor ama sınıflandırma gelmiyor. Kayıt
    // olmadan bunları ayırmanın tek yolu cihazda hata ayıklamak; Mac'siz geliştirmede mümkün değil.
    private(set) var framesProcessed = 0
    private(set) var facesFound = 0
    private(set) var framesClassified = 0
    private(set) var lastError: String?
    private var errorLogged = false
    /// Son karenin piksel boyutu. Döndürmenin GERÇEKTEN uygulanıp uygulanmadığını tek başına
    /// söyler: portre bir oturumda 1080x1920 beklenir, 1920x1080 görürsek buffer sensör
    /// yönelimindedir ve ML Kit'in yüz bulamaması bunun doğrudan sonucudur.
    private(set) var lastFrameSize: CGSize = .zero

    // MARK: Giriş yolu yoklaması
    //
    // Oryantasyon yoklaması ELENDİ: cihaz kaydı dört oryantasyonu da denedi, hiçbiri yüz bulmadı,
    // ve `boyut=1080x1920` buffer'ın zaten DİK geldiğini kanıtladı. Yön `.up`'ta sabit.
    //
    // Geriye kalan şüpheli giriş YOLU. Ölçüm şunu söylüyordu: 445 kare, 0 yüz, 0 hata, kare başına
    // ~210 ms. Bu süre ML Kit'in modelleri yükleyip GERÇEKTEN çıkarım yaptığı anlamına geliyor —
    // model bulunamasaydı anında dönerdi. Yani dedektör çalışıyor ama gördüğü görüntüde yüz yok.
    // `VisionImage(buffer:)` ile `VisionImage(image:)` ML Kit içinde AYRI kod yolları; ikincisi
    // uygulamanın aylardır hizalanmış selfie üretmek için kullandığı CGImage dönüşümüne dayanıyor,
    // yani çalıştığı BİLİNEN bir yol.
    //
    // Bir süre yüz çıkmazsa CGImage yoluna geçilir; yüz bulan yol KİLİTLENİR ve loglanır.
    private enum InputPath: String { case buffer, cgimage }
    /// ⚖️ ÖLÇÜLDÜ (cihaz kaydı 2026-08-25): `buffer` yolu 445 karede 0 yüz, `cgimage` yolu 158
    /// karede 135 yüz ve %100 sınıflandırma verdi. Yani varsayılan artık tahmin değil, veri.
    /// `buffer` yoklama seçeneği olarak duruyor: başka bir cihazda tersi çıkarsa kendiliğinden
    /// oraya geçsin — ama hiçbir cihaz artık çalışmayan yolla 4 saniye kaybetmesin.
    private var inputPath: InputPath = .cgimage
    private var pathLocked = false
    private var framesSincePathSwitch = 0
    /// ~4 saniye @4.7fps — 15 saniyelik hareket penceresine sığar.
    private static let pathProbeFrames = 20

    /// Oturum sonunda tek satırda loglanır (kota: doğrulama başına 1 olay).
    var diagnostics: String {
        "mlkit kare=\(framesProcessed) yüz=\(facesFound) sınıflandırılmış=\(framesClassified) "
            + "yol=\(inputPath.rawValue)\(pathLocked ? "(kilitli)" : "(yokluyor)") "
            + "boyut=\(Int(lastFrameSize.width))x\(Int(lastFrameSize.height))"
            + " " + timing.summary
            + (lastError.map { " hata=\($0)" } ?? "")
    }

    func resetDiagnostics() {
        framesProcessed = 0
        facesFound = 0
        framesClassified = 0
        lastError = nil
        errorLogged = false
        timing.reset()
        // Giriş yolu KİLİDİ kasten sıfırlanmaz: bir kez çözüldüyse bu cihaz için doğrudur,
        // her denemede baştan yoklamak yalnız zaman kaybettirir.
    }

    /// `CameraController.onSampleBuffer` ile çağrılır. ML Kit `VisionImage`'ının `CVPixelBuffer`
    /// init'i olmadığı için giriş `CMSampleBuffer`; pixel buffer ondan türetilir.
    func process(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        framesProcessed += 1
        timing.tick()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lastError = "sample buffer'da görüntü yok"
            onNoFace?()
            return
        }
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        lastFrameSize = imageSize

        // Küçültme YALNIZ cgimage yolunda; buffer yolu ham kareyi verir (ölçek 1).
        let detectionScale = (inputPath == .cgimage && imageSize.width > 0)
            ? min(1, Self.detectionMaxWidth / imageSize.width) : 1
        let coordinateScale = detectionScale > 0 ? 1 / detectionScale : 1

        let image: VisionImage
        switch inputPath {
        case .buffer:
            image = VisionImage(buffer: sampleBuffer)
        case .cgimage:
            guard let ui = timing.measure("dönüşüm", { uiImage(from: pixelBuffer, scale: detectionScale) }) else {
                lastError = "pixel buffer UIImage'a çevrilemedi"
                onNoFace?()
                return
            }
            image = VisionImage(image: ui)
        }
        // Buffer'ın dik geldiği ÖLÇÜLDÜ (1080x1920) → yön sabit.
        image.orientation = .up

        let faces: [Face]
        let detectStart = Date().timeIntervalSince1970 * 1000
        do {
            faces = try detector.results(in: image)
            timing.record("mlkit", Date().timeIntervalSince1970 * 1000 - detectStart)
        } catch {
            timing.record("mlkit", Date().timeIntervalSince1970 * 1000 - detectStart)
            lastError = error.localizedDescription
            // İLK hata hemen bildirilir: oturum 95 saniye sürebiliyor ve dedektör hiç çalışmıyorsa
            // bunu oturum sonunu beklemeden bilmek gerekir. Oturum başına EN FAZLA bir olay.
            if !errorLogged {
                errorLogged = true
                Log.error("ML Kit yüz tespiti hata verdi", error: error, category: .liveness)
            }
            onNoFace?()
            return
        }

        guard let face = faces.max(by: { boxArea($0.frame) < boxArea($1.frame) }) else {
            advanceInputPathProbeIfStuck()
            onNoFace?()
            return
        }
        facesFound += 1
        if !pathLocked {
            pathLocked = true
            Log.info("ML Kit giriş yolu çözüldü: \(inputPath.rawValue)", category: .liveness)
        }

        onFace?(Frame(signals: makeSignals(face, coordinateScale: coordinateScale),
                      pixelBuffer: pixelBuffer,
                      imageSize: imageSize,
                      orientation: orientation))
    }

    // MARK: - Face → FaceSignals

    /// `coordinateScale`: ML Kit küçültülmüş görüntüde ölçtü → kutu ve landmark'lar tam çözünürlük
    /// piksel uzayına geri çarpılır. `FaceAligner` ve `captureFrame` ham buffer'dan kırptığı için
    /// bu geri ölçekleme ZORUNLU; atlanırsa hizalama ve kırpma yanlış yerden alır.
    private func makeSignals(_ face: Face, coordinateScale: CGFloat) -> FaceSignals {
        // Sınıflandırma olasılıkları bu karede GERÇEKTEN geldi mi? Gelmediyse kare bir ölçüm
        // değildir ve jest kararında kullanılmamalı (bkz. FaceSignals.landmarksOK).
        let classified = face.hasSmilingProbability
            && face.hasLeftEyeOpenProbability
            && face.hasRightEyeOpenProbability
        if classified { framesClassified += 1 }

        // Eksik değerler Android'in varsayılanlarıyla doldurulur; jest yolu zaten `landmarksOK`
        // ile korunduğu için bunlar yalnız kalite skoruna (best-frame seçimi) girer.
        let smile = face.hasSmilingProbability ? Float(face.smilingProbability) : 0
        let leftOpen = face.hasLeftEyeOpenProbability ? Float(face.leftEyeOpenProbability) : 0.5
        let rightOpen = face.hasRightEyeOpenProbability ? Float(face.rightEyeOpenProbability) : 0.5

        return FaceSignals(
            yaw: (face.hasHeadEulerAngleY ? Float(face.headEulerAngleY) : 0) * yawSign,
            pitch: face.hasHeadEulerAngleX ? Float(face.headEulerAngleX) : 0,
            roll: face.hasHeadEulerAngleZ ? Float(face.headEulerAngleZ) : 0,
            leftEyeOpen: leftOpen,
            rightEyeOpen: rightOpen,
            smile: smile,
            boundingBox: face.frame.applying(CGAffineTransform(scaleX: coordinateScale, y: coordinateScale)),
            leftEye: point(face, .leftEye, coordinateScale),
            rightEye: point(face, .rightEye, coordinateScale),
            landmarksOK: classified
        )
    }

    /// Landmark konumu (top-left piksel uzayı — ML Kit girdi görüntüsüyle aynı uzayı kullanır).
    /// ⚠️ Sol/sağ ADLANDIRMASINA güvenilmez: `FaceAligner` gözleri X'e göre kendisi sıralar.
    private func point(_ face: Face, _ type: FaceLandmarkType, _ scale: CGFloat) -> CGPoint? {
        guard let p = face.landmark(ofType: type)?.position else { return nil }
        return CGPoint(x: p.x * scale, y: p.y * scale)
    }

    /// Kilitlenmemişken uzun süre yüz çıkmazsa diğer giriş yolunu dener (dönüşümlü).
    private func advanceInputPathProbeIfStuck() {
        guard !pathLocked else { return }
        framesSincePathSwitch += 1
        guard framesSincePathSwitch >= Self.pathProbeFrames else { return }
        framesSincePathSwitch = 0
        inputPath = (inputPath == .buffer) ? .cgimage : .buffer
    }

    /// Pixel buffer → UIImage. `VisionImage(image:)` yolu için; uygulamanın hizalanmış selfie
    /// üretirken aylardır kullandığı dönüşümün aynısı (CIContext tabanlı).
    private func uiImage(from pixelBuffer: CVPixelBuffer, scale: CGFloat) -> UIImage? {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if scale < 1 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func boxArea(_ r: CGRect) -> CGFloat { r.width * r.height }
}

/// Video kuyruğundaki aşamaların en uzun sürelerini biriktirir.
///
/// Cihazda debugger yok; bir donmanın HANGİ aşamada olduğunu ölçmeden bilmenin yolu da yok.
/// 2026-08-25 kaydında uygulama 77 saniye tamamen durdu (ne kare işlendi ne bekleyen iş koştu),
/// sonra kendiliğinden çözüldü — yani kilitlenme değil, kaynak tıkanması. Hangi aşamanın
/// tıkadığını bu sayaçlar söyleyecek.
final class StageTimer {
    private(set) var maxMs: [String: Double] = [:]
    private(set) var maxGapMs: Double = 0
    private var lastTickMs: Double = 0

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    func measure<T>(_ stage: String, _ body: () -> T) -> T {
        let t0 = Self.nowMs
        let result = body()
        record(stage, Self.nowMs - t0)
        return result
    }

    func record(_ stage: String, _ ms: Double) {
        if ms > (maxMs[stage] ?? 0) { maxMs[stage] = ms }
    }

    /// Kare girişleri arasındaki en uzun boşluk. Ölçülen aşamaların DIŞINDA kalan tıkanmayı
    /// yakalar: aşama süreleri küçük ama boşluk büyükse duraklama bizim kodumuzda değildir.
    func tick() {
        let now = Self.nowMs
        if lastTickMs > 0 { maxGapMs = max(maxGapMs, now - lastTickMs) }
        lastTickMs = now
    }

    func reset() {
        maxMs = [:]
        maxGapMs = 0
        lastTickMs = 0
    }

    var summary: String {
        let top = maxMs.sorted { $0.value > $1.value }.prefix(4)
            .map { "\($0.key)=\(Int($0.value))" }.joined(separator: ",")
        return "enUzun[\(top)] boşluk=\(Int(maxGapMs))"
    }
}
