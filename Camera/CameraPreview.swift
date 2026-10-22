import SwiftUI
import AVFoundation

/// SwiftUI kamera önizlemesi — Android `viewFinder` (PreviewView surface) eşdeğeri.
/// `AVCaptureVideoPreviewLayer`'ı bir `UIView` olarak SwiftUI'a köprüler.
///
/// Oturumu değil CONTROLLER'ı alır: önizleme ekrandan kalkarken oturumun önce kendi kuyruğunda
/// durması gerekiyor (bkz. `CameraController.retirePreview`, IOS-3R).
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    /// Dokunulan nokta, kamera AYGITI koordinatında (0-1) — nil ise dokunma dinlenmez (QR ekranı
    /// dokunarak odaklama için verir).
    var onTapDevicePoint: ((CGPoint) -> Void)? = nil

    /// Söküm anında hangi controller'a teslim edileceğini taşır (`dismantleUIView` statik).
    final class Coordinator {
        var camera: CameraController
        init(camera: CameraController) { self.camera = camera }
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = camera.session
        view.videoPreviewLayer.videoGravity = gravity
        view.onTapDevicePoint = onTapDevicePoint
        if onTapDevicePoint != nil {
            view.addGestureRecognizer(
                UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:))))
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.camera = camera
        // Yalnız gerçekten değiştiyse: aynı oturumu yeniden atamak bile çalışan oturumda bağlantıyı
        // söküp takabilir — ana iş parçacığında yeniden yapılandırma demek.
        if uiView.videoPreviewLayer.session !== camera.session {
            uiView.videoPreviewLayer.session = camera.session
        }
        uiView.onTapDevicePoint = onTapDevicePoint
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.camera.retirePreview(uiView)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTapDevicePoint: ((CGPoint) -> Void)?

        /// Ekran noktası → aygıt noktası: katman yerçekimini, yönü ve aynayı kendisi hesaba katar.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let layerPoint = recognizer.location(in: self)
            onTapDevicePoint?(videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
        }
    }
}
