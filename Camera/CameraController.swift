import AVFoundation
import CoreVideo
import CoreMedia
import Combine
import ImageIO

/// Kamera oturumu sarmalayıcı — Android `camera/CameraManager` + `LivenessActivity.startCamera`
/// eşdeğeri. `AVCaptureSession` + video-data-output ile her kareyi (CVPixelBuffer) bir
/// analiz closure'ına verir. Kamera pozisyonu parametrik (.back: MRZ/QR, .front: liveness).
///
/// İzin reddi/çalışma durumu `@Published` ile UI'a yansır. Tüm oturum işlemleri ayrı kuyrukta.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    let position: AVCaptureDevice.Position
    /// QR ekranı için: çözünürlüğü 1080p'ye sabitle + bu çözünürlükte mümkün olan en yüksek fps.
    /// Liveness (ön kamera) embedding paritesi için 1080p@30 preset korunur (false).
    private let highFrameRate: Bool
    /// Kamera yapılandırılınca uygulanan başlangıç zoom faktörü (QR ekranı 2x açılır).
    private let defaultZoom: CGFloat

    @Published var permissionDenied = false
    @Published var configurationFailed = false
    @Published private(set) var isRunning = false

    private let sessionQueue = DispatchQueue(label: "com.verifyblind.camera.session")
    private let videoQueue = DispatchQueue(label: "com.verifyblind.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var videoDevice: AVCaptureDevice?

    /// Her kare için çağrılır (video kuyruğunda): (pixelBuffer, Vision orientation).
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    init(position: AVCaptureDevice.Position, highFrameRate: Bool = false, defaultZoom: CGFloat = 1.0) {
        self.position = position
        self.highFrameRate = highFrameRate
        self.defaultZoom = defaultZoom
        super.init()
    }

    // Controller dealloc olunca kamerayı kesin bırak — aksi halde ekran yeniden açılışta
    // siyah kalabiliyor (eski oturum cihazı tutuyor). Cihaz geri bildirimi 2026-06-07.
    deinit {
        if session.isRunning { session.stopRunning() }
    }

    /// İzin ister, gerekiyorsa yapılandırır ve oturumu başlatır.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginSession()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// Dijital zoom oranını ayarlar (QR tarama 1.5x/2x/3x butonları — Android `CameraManager.setZoom` paritesi).
    /// 1.0 = tam geniş açı. Cihazın min/max sınırlarına ve makul bir tavana (5x) kırpılır.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 8.0)
                device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(factor, maxZoom))
                device.unlockForConfiguration()
            } catch {
                Log.error("CameraController: zoom ayarlanamadı: \(error.localizedDescription)", category: .liveness)
            }
        }
    }

    /// Logic'i kare işleme ile AYNI seri kuyrukta çalıştırır (paylaşılan durum yarışını önler).
    /// Liveness orkestrasyonu start/reset/timeout'u buradan geçirir → tek seri pipeline.
    func runOnVideoQueue(_ block: @escaping () -> Void) {
        videoQueue.async(execute: block)
    }

    private func beginSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configure()
            }
            guard self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    private func configure() {
        session.beginConfiguration()

        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first,
        let input = try? AVCaptureDeviceInput(device: device),
        session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.configurationFailed = true }
            Log.error("CameraController: giriş eklenemedi (pos=\(position.rawValue))", category: .liveness)
            return
        }
        session.addInput(input)
        videoDevice = device

        // Çözünürlük: 1080p. QR'da bu çözünürlükte max fps için manuel format (preset .inputPriority);
        // uygun format yoksa veya liveness'ta preset tabanlı 1080p@30 korunur.
        if highFrameRate, let format = best1080pHighFpsFormat(device) {
            session.sessionPreset = .inputPriority
            configureHighFrameRate(device, format: format)
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        configureDevice(device)

        output.setSampleBufferDelegate(self, queue: videoQueue)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.configurationFailed = true }
            return
        }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            // Ön kamera selfie aynası — Android ön kamera davranışıyla aynı.
            if position == .front, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
            // Video stabilizasyonunu kapat — EIS yüzü "warp" edip embedding'i bozabilir (filtre off).
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .off
            }
        }

        session.commitConfiguration()
        configured = true
    }

    /// AE/AF metering + post-process kapatma (Android Camera2Interop + FocusMeteringAction paritesi).
    /// Yüzün geleceği MERKEZE odak/pozlama metering → sahnede gezinmeyi durdurur, pozlama "av peşinde"
    /// gidip kareleri yakıp karartmaz. Video-HDR ton eşlemesi kapatılır (smoothing/clamp önler).
    /// Sert `.locked` yerine merkeze-sabitli `.continuousAuto*`: kullanıcı kayarsa pozlama bozulmaz.
    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            // Video-HDR (ton eşleme/clamp) kapat — biyometri için en sadık ham görüntü.
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            // Başlangıç zoom'u (QR ekranı 2x açılır) — cihaz sınırlarına kırp.
            if defaultZoom > 1.0 {
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 8.0)
                device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(defaultZoom, maxZoom))
            }
            device.unlockForConfiguration()
        } catch {
            Log.error("CameraController: cihaz yapılandırılamadı: \(error.localizedDescription)", category: .liveness)
        }
    }

    /// 1080p (1920×1080) formatları arasında 60 fps'i destekleyen, 60'a en yakın olanı seçer
    /// (120/240 slo-mo formatlarından kaçınır — çok kısa pozlama taramaya zarar verir). Yoksa nil.
    private func best1080pHighFpsFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = Double.greatestFiniteMagnitude
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == 1920, dims.height == 1080 else { continue }
            let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            guard maxFps >= 30 else { continue }
            // 60'a yakınlık skoru (küçük = iyi): >=60 ise fazlalık, <60 ise büyük ceza.
            let score = maxFps >= 60 ? (maxFps - 60) : (1000 - maxFps)
            if score < bestScore { bestScore = score; best = format }
        }
        return best
    }

    /// Seçili 1080p formatını uygular ve fps'i (≤60) en yükseğe çıkarır. Alt sınır 15'e kadar
    /// adaptif bırakılır → iyi ışıkta max fps, düşük ışıkta pozlamayı uzatabilir.
    private func configureHighFrameRate(_ device: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let maxFps = min(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30, 60)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(maxFps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
            device.unlockForConfiguration()
        } catch {
            Log.error("CameraController: yüksek fps ayarlanamadı: \(error.localizedDescription)", category: .liveness)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // .portrait + (ön kamerada) ayna uygulandığı için buffer dik → Vision .up.
        onFrame?(pixelBuffer, .up)
    }
}
