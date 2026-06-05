import Vision
import CoreVideo

/// MRZ kamera tarayıcı — Android `util/MrzAnalyzer` (MLKit text) eşdeğeri (Vision ile).
///
/// `CameraController.onFrame`'e bağlanır; her kareyi `VNRecognizeTextRequest` ile tanır,
/// metni saf `MRZParser`'a verir ve `MRZStabilityTracker` ile 3 kararlı okumada `onResult`
/// çağırır (ana kuyrukta). `onResult` çıktısı `MRZKey.mrzKey` ile birleşip NFC'yi sürer.
final class MRZScanner {

    /// 3 ardışık kararlı okumada ana kuyrukta çağrılır.
    var onResult: ((MRZParser.Result) -> Void)?

    private let tracker = MRZStabilityTracker()
    private let request: VNRecognizeTextRequest
    private var isAnalyzing = false

    init() {
        request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // MRZ doğal dil değil (OCR-B)
        request.recognitionLanguages = ["en-US"]
    }

    /// `CameraController.onFrame` ile çağrılır (video kuyruğunda).
    func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return }

        let text = lines.joined(separator: "\n")
        guard let parsed = MRZParser.parse(text), let stable = tracker.accept(parsed) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onResult?(stable)
        }
    }

    func reset() {
        tracker.reset()
    }
}
