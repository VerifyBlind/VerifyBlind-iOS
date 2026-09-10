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

    /// Kare toplama üst sınırı. Dolduğunda elde kabul edilebilir kare varsa o gönderilir, yoksa
    /// ekran hata ile kapanır ve giriş REDDEDİLİR ("kare alamadık" asla "geçti" değildir).
    private static let captureTimeout: TimeInterval = 20

    /// İlk iyi kareden sonra iyileşme için beklenen süre. Anında dönmek en iyi kareyi değil İLK
    /// kabul edilebilir kareyi seçerdi.
    private static let settleSeconds: TimeInterval = 1.2

    let camera = CameraController(position: .front)
    private let analyzer = FaceAnalyzer()

    @Published private(set) var statusKey = "login_face_status_looking"
    @Published private(set) var warning: String?

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
    private var firstGoodFrameAt: Date?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    func start() {
        startedAt = Date()

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

        // Sunum alanları ANA kuyruğa marshal edilir — burası video kuyruğu.
        let warnText: String? =
            (sharpness >= 0 && sharpness <= Self.minSharpness) ? L.t("login_face_warn_blur")
            : (!poseOK ? L.t("login_face_warn_pose") : nil)
        DispatchQueue.main.async { [weak self] in
            self?.warning = warnText
            self?.statusKey = warnText == nil ? "login_face_status_hold" : "login_face_status_looking"
        }

        // Kalite skoru: netlik + poz. Cihaz BENZERLİK ölçmez (bloklamaz) — bu skor yalnız hangi
        // karenin enclave'e gideceğini seçer.
        let quality = (sharpness > 0 ? sharpness : 0) + (poseOK ? 50 : 0)
        guard quality > bestQuality else { return }

        // PNG (lossless): ArcFace girişi tam bu 112×112 piksel; bu boyutta JPEG blok artefaktı
        // embedding'i bozabilir.
        guard let png = UIImage(cgImage: aligned).pngData(),
              let cropJPEG = Self.makeAntiSpoofCrop(fullCG: fullCG, box: box) else { return }

        selfiePNG = png
        antiSpoofCropJPEG = cropJPEG
        bestQuality = quality

        let faceFrac = frame.imageSize.width > 0 ? Float(box.width / frame.imageSize.width) : -1
        // Cihaz ölçüleri enclave'de DOĞRULANMAZ — yalnız teşhis satırına yazılır.
        // `deviceMatchScore` bilerek nil: girişte cihaz benzerlik ölçmüyor ve 0 göndermek ölçüm
        // satırında "hiç benzemedi" gibi okunurdu. Jest sayaçları da nil — girişte jest yok.
        frameMetrics = SimilarityStreamer.metricsOf(
            deviceMatchScore: nil,
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

        if firstGoodFrameAt == nil, poseOK, sharpness > Self.minSharpness {
            firstGoodFrameAt = Date()
        }
        if let first = firstGoodFrameAt, Date().timeIntervalSince(first) >= Self.settleSeconds {
            succeed()
        }
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
