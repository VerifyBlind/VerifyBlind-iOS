import SwiftUI
import AVFoundation

/// SwiftUI kamera önizlemesi — Android `viewFinder` (PreviewView surface) eşdeğeri.
/// `AVCaptureVideoPreviewLayer`'ı bir `UIView` olarak SwiftUI'a köprüler.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    /// Dokunulan nokta, kamera AYGITI koordinatında (0-1) — nil ise dokunma dinlenmez (QR ekranı
    /// dokunarak odaklama için verir).
    var onTapDevicePoint: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = gravity
        view.onTapDevicePoint = onTapDevicePoint
        if onTapDevicePoint != nil {
            view.addGestureRecognizer(
                UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:))))
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.onTapDevicePoint = onTapDevicePoint
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
