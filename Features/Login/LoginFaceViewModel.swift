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
///   • JEST YOK. Giriş ~2 saniyede bitmeli, yoksa 2FA/step-up kullanım alanı ölür.
///   • Tek kare. Aday listesi, streaming, "en iyi kare" yarışı yok.
///   • Cihaz-içi karşılaştırma YOK. Otoriter karar enclave'dedir; burada bir eşik uygulamak
///     yanlış-red üretirdi (canlı benzerlik akışının ilk ölçümü: 6 streaming karesinin 4'ünde
///     cihaz reddederdi, enclave hepsini geçirdi).
///
/// 🔴 K6: selfie ve anti-spoof kırpması AYNI KAREDEN üretilir. Benzerlik bir kareden, canlılık
/// başkasından alınırsa gerçek bir açık doğar — ikisi tek `captureFrame` çağrısında, tek
/// `CGImage`'dan çıkar.
///
/// İPLİK DİSİPLİNİ: `LivenessViewModel` ile aynı — kare mantığı yalnız kamera VİDEO KUYRUĞUNDA
/// koşar (`analyzer.onFace`), `@Published` sunum alanları ana kuyruğa marshal edilir. Bu yüzden
/// `@MainActor` KULLANILMAZ: kare işlemeyi ana kuyruğa taşımak throttle ve kalite mantığını bozar.
final class LoginFaceViewModel: ObservableObject {

    /// Kare "yeterince iyi" sayılmadan önceki en düşük netlik (112×112 gradyan enerjisi).
    /// `LivenessViewModel.blurWarnThreshold` ile aynı ölçek.
    private static let minSharpness: Float = 45

    /// Kare toplama üst sınırı — kullanıcıya tanınan AZAMİ fırsat süresi.
    ///
    /// Eşiği geçemeyen kullanıcı bu süre boyunca gözlüğünü çıkarabilir, ışığa dönebilir.
    /// Dolduğunda eldeki EN İYİ kare yine gönderilir: cihaz skoru enclave kararı DEĞİLDİR
    /// (farklı model, farklı eşik) ve burada reddetmek enclave'in geçireceği kullanıcıyı kapıda
    /// durdurmak olurdu. Hiç kare yoksa giriş iptal (fail-closed).
    private static let captureTimeout: TimeInterval = 30

    /// Benzerlik eşiği geçildikten SONRA beklenen süre — bu 1 saniyede daha iyi kare gelirse o gider.
    private static let settleSeconds: TimeInterval = 1.0

    /**
     * "Yeterince benziyor" sınırı: ekrandaki yüzdenin yeşile döndüğü VE ekranın erken bitebildiği
     * eşik. Kayıt akışındaki 0.65 ile aynı sayı.
     *
     * ⚠️ Bu bir KAPI DEĞİLDİR. Altında kalmak submit'i engellemez; yalnızca ekranın hemen
     * kapanmasını engeller, yani kullanıcıya düzeltme fırsatı verir. Süre dolunca eldeki en iyi
     * kare koşulsuz gider ve kararı enclave verir (ArcFace, eşik 0.20 — bu sayıyla KIYASLANAMAZ).
     */
    private static let scoreHintGood: Float = 0.65

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()
    private let embedder = FaceEmbedder()

    @Published private(set) var statusKey = "login_face_status_looking"
    @Published private(set) var warning: String?
    /// Canlı benzerlik yüzdesi (0-100) — nil ise gösterge gizli.
    @Published private(set) var matchPercent: Int?
    /// Yüzde yeşil mi gösterilecek (yalnız sunum).
    @Published private(set) var matchIsGood = false

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

    /// Başarı: (hizalanmış 112×112 selfie PNG, AYNI karenin 2,7× 80×80 anti-spoof JPEG'i, ölçüler).
    /// iOS'ta kareler `Data` olarak bellekte taşınır (Android dosya yolu tutar) — mevcut ayrım.
    var onSuccess: ((Data, Data, DeviceFrameMetrics?) -> Void)?

    /// Kare alınamadı / kullanıcı vazgeçti → çağıran giriş isteğini GÖNDERMEZ (fail-closed).
    var onFailure: (() -> Void)?

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

    func start() {
        startedAt = Date()

        // Referans embedding'i BİR KEZ — kamera kuyruğunu her karede meşgul etmesin.
        // Başarısız olursa yalnız % göstergesi kaybolur; akış aynen sürer, çünkü gerçek
        // karşılaştırma zaten enclave'de yapılıyor.
        if let b64 = faceRefB64, !b64.isEmpty {
            camera.runOnVideoQueue { [weak self] in
                guard let self,
                      let data = Data(base64Encoded: b64),
                      let cg = UIImage(data: data)?.cgImage else {
                    Log.warning("Yüz referansı çözülemedi — % göstergesi kapalı", category: .liveness)
                    return
                }
                // Kayıt akışındaki chip embedding ile AYNI hizalama.
                let eyes = LivenessViewModel.detectEyes(in: cg)
                guard let aligned = FaceAligner.alignedImage(
                        from: cg, leftEye: eyes.left, rightEye: eyes.right) else { return }
                self.refEmbedding = self.embedder.embedding(from: aligned)
            }
        }

        camera.onFrame = { [weak self] buffer, _ in
            // Video kuyruğu — logic durumu burada yazılır (LivenessViewModel disiplini).
            self?.lastLuma = LivenessViewModel.averageLuma(buffer)
        }
        // ML Kit `VisionImage` CVPixelBuffer kabul etmiyor → yüz analizi ayrı kanaldan beslenir.
        // Aynı kare, aynı video kuyruğu; yalnız taşıyıcı tip farklı (LivenessViewModel ile aynı kalıp).
        camera.onSampleBuffer = { [weak self] sample, orientation in
            self?.analyzer.process(sample, orientation: orientation)
        }
        analyzer.onFace = { [weak self] frame in
            self?.captureFrame(frame)   // video kuyruğu
        }
        camera.start()

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.captureTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Zaman aşımı da video kuyruğuna alınır: `finished` ve kare alanları orada yaşıyor,
            // başka bir kuyruktan okumak yarış olurdu.
            self?.camera.runOnVideoQueue { self?.handleTimeout() }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        camera.stop()
    }

    /// Kullanıcı ekranı kapattı → kare yok, giriş gönderilmez.
    ///
    /// UI'dan (ana kuyruk) çağrılır ama `finished` video kuyruğunda yaşıyor: bayrağı oradan
    /// çevirmezsek koşan bir `captureFrame` iptali görmeyip başarıyı da bildirebilirdi.
    func cancel() {
        camera.runOnVideoQueue { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            DispatchQueue.main.async {
                self.stop()
                self.onFailure?()
            }
        }
    }

    /// Tek kareden selfie + anti-spoof kırpmasını üretir. `LivenessViewModel.captureFrame` ile AYNI
    /// boru hattı (aynı marj, aynı hizalama, aynı 2,7× oran ve boyutlar) — enclave iki akışta da
    /// aynı modelleri çalıştırdığı için girdi de aynı olmalı, yoksa girişteki skorlar kayıttakilerle
    /// kıyaslanamaz hâle gelir.
    private func captureFrame(_ frame: FaceAnalyzer.Frame) {
        guard !finished else { return }
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
            self?.warning = warnText
            self?.statusKey = statusText
            self?.matchPercent = showScore ? percent : nil
            self?.matchIsGood = isGood
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
        // dolduysa gönderilir.
        guard quality > bestQuality else {
            if settled, selfiePNG != nil, antiSpoofCropJPEG != nil { succeed() }
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
        // ⚠️ Bu sayı enclave skoruyla KIYASLANAMAZ. Jest sayaçları nil — girişte jest yok.
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

        if settled { succeed() }
    }

    /// Süre doldu. Elde kabul edilebilir kare varsa gönderilir: kullanıcıyı mükemmel kare için
    /// sonsuza kadar bekletmek, enclave'in zaten geçirebileceği bir kareyi çöpe atardı.
    private func handleTimeout() {
        guard !finished else { return }
        if selfiePNG != nil, antiSpoofCropJPEG != nil {
            Log.info("Giriş karesi: süre doldu, eldeki en iyi kare gönderiliyor (kalite=\(Int(bestQuality)))",
                     category: .liveness)
            succeed()
        } else {
            Log.warning("Giriş karesi: süre doldu, kullanılabilir kare yok — giriş iptal", category: .liveness)
            finished = true
            stop()
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        }
    }

    private func succeed() {
        guard !finished else { return }
        // Kırpma olmadan selfie GÖNDERİLMEZ: enclave canlılığı fail-closed uyguluyor, eksik kırpma
        // orada nasılsa reddedilir — kullanıcıyı ağ turu sonrası değil, burada durdur.
        guard let png = selfiePNG, let crop = antiSpoofCropJPEG else {
            finished = true
            stop()
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            return
        }
        finished = true
        stop()
        Log.info("Giriş karesi hazır (kalite=\(Int(bestQuality)))", category: .liveness)
        let metrics = frameMetrics
        // Geri çağrı akış durumunu (`step`) değiştiriyor → ANA kuyruk.
        DispatchQueue.main.async { [weak self] in self?.onSuccess?(png, crop, metrics) }
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
