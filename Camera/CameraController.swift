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
        session.sessionPreset = .high

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
        }

        session.commitConfiguration()
        configured = true
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
