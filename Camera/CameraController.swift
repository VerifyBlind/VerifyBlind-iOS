import AVFoundation
import CoreVideo
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

    init(position: AVCaptureDevice.Position) {
        self.position = position
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
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 5.0)
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
        // En yüksek analiz çözünürlüğü (Android 1920×1080 paritesi; landmark/embedding hassasiyeti).
        // Cihaz desteklemiyorsa .high'a düş.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

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
            device.unlockForConfiguration()
        } catch {
            Log.error("CameraController: cihaz yapılandırılamadı: \(error.localizedDescription)", category: .liveness)
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
