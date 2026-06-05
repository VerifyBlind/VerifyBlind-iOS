import Vision
import CoreVideo

/// QR/DataMatrix kamera tarayıcı — Android `util/QrAnalyzer` eşdeğeri (Vision ile).
///
/// `CameraController.onFrame`'e bağlanır; ilk boş-olmayan barkod payload'ında bir kez
/// `onResult` çağırır (ana kuyrukta) ve `found` ile durur. Partner login nonce akışı (Aşama 4)
/// için kullanılacak. `reset()` ile yeniden taranabilir.
final class QRScanner {

    /// İlk geçerli barkodda ana kuyrukta bir kez çağrılır.
    var onResult: ((String) -> Void)?

    private let request: VNDetectBarcodesRequest
    private var found = false

    init() {
        request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .dataMatrix]
    }

    /// `CameraController.onFrame` ile çağrılır (video kuyruğunda).
    func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard !found else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])

        for result in request.results ?? [] {
            if let payload = result.payloadStringValue, !payload.isEmpty {
                found = true
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(payload)
                }
                break
            }
        }
    }

    func reset() {
        found = false
    }
}
