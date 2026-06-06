import Vision
import CoreVideo
import CoreGraphics

/// Yüz tespiti — Android `util/LivenessAnalyzer` (MLKit Face) eşdeğeri (Vision ile).
///
/// `VNDetectFaceLandmarksRequest` çalıştırır, en büyük yüzü seçer ve `FaceSignals`'a çevirir.
/// MLKit'in hazır verdiği eye-open/smile olasılıkları Vision'da YOK → göz landmark açıklık
/// oranından (EAR) ve ağız geometrisinden TÜRETİLİR (eşikler cihazda kalibre edilebilir).
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

    /// MLKit ↔ Vision yaw işareti + ön kamera aynası kalibrasyonu. **Cihaz testinde sol/sağ ters
    /// çıktı (2026-06-06) → -1** (Android'deki "SWAPPED Directions" pragmatiğinin iOS karşılığı).
    var yawSign: Float = -1

    private let request = VNDetectFaceLandmarksRequest()
    private var isAnalyzing = false

    func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            onNoFace?()
            return
        }

        let faces = request.results ?? []
        guard let face = faces.max(by: { boxArea($0.boundingBox) < boxArea($1.boundingBox) }) else {
            onNoFace?()
            return
        }

        let signals = makeSignals(face, imageSize: imageSize)
        onFace?(Frame(signals: signals, pixelBuffer: pixelBuffer, imageSize: imageSize, orientation: orientation))
    }

    // MARK: - VNFaceObservation → FaceSignals

    private func makeSignals(_ face: VNFaceObservation, imageSize: CGSize) -> FaceSignals {
        let yawDeg = degrees(face.yaw) * yawSign
        let pitchDeg = degrees(face.pitch)
        let rollDeg = degrees(face.roll)

        let leftEyeOpen = eyeOpenProbability(face.landmarks?.leftEye, imageSize: imageSize)
        let rightEyeOpen = eyeOpenProbability(face.landmarks?.rightEye, imageSize: imageSize)

        let bbox = topLeftRect(face.boundingBox, imageSize: imageSize)
        let leftEye = eyeCenter(face.landmarks?.leftEye, imageSize: imageSize)
        let rightEye = eyeCenter(face.landmarks?.rightEye, imageSize: imageSize)

        // Smile sinyali = ağız genişliği / göz arası mesafe (stabil referans). Nötr ~1.0,
        // gülümseme ~1.2+. SmileDetector bunu kişinin nötr seviyesine göre değerlendirir.
        let smile = smileSpread(face.landmarks, leftEye: leftEye, rightEye: rightEye,
                                imageSize: imageSize, faceBox: bbox)

        return FaceSignals(
            yaw: yawDeg, pitch: pitchDeg, roll: rollDeg,
            leftEyeOpen: leftEyeOpen, rightEyeOpen: rightEyeOpen, smile: smile,
            boundingBox: bbox, leftEye: leftEye, rightEye: rightEye
        )
    }

    // MARK: - Türetim yardımcıları

    private func degrees(_ radians: NSNumber?) -> Float {
        guard let r = radians?.floatValue else { return 0 }
        return r * 180 / .pi
    }

    private func boxArea(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Normalize (bottom-left) bbox → top-left piksel rect.
    private func topLeftRect(_ normalized: CGRect, imageSize: CGSize) -> CGRect {
        let r = VNImageRectForNormalizedRect(normalized, Int(imageSize.width), Int(imageSize.height))
        return CGRect(x: r.origin.x, y: imageSize.height - r.origin.y - r.height, width: r.width, height: r.height)
    }

    /// Bottom-left landmark noktalarını top-left piksel uzayına çevirir.
    private func topLeftPoints(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> [CGPoint] {
        guard let pts = region?.pointsInImage(imageSize: imageSize) else { return [] }
        return pts.map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
    }

    /// Göz açıklık oranı (EAR benzeri) → [0,1] açıklık olasılığı. Kapalı ~0.08, açık ~0.28+.
    private func eyeOpenProbability(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> Float {
        let pts = topLeftPoints(region, imageSize: imageSize)
        guard pts.count >= 4 else { return 0.5 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        let h = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard w > 0 else { return 0.5 }
        let aspect = Float(h / w)
        return min(max((aspect - 0.10) / (0.28 - 0.10), 0), 1)
    }

    /// Göz merkezleri (top-left piksel). Hizalama için.
    private func eyeCenter(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        let pts = topLeftPoints(region, imageSize: imageSize)
        guard !pts.isEmpty else { return nil }
        let sx = pts.reduce(0) { $0 + $1.x }
        let sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }

    /// Smile sinyali = ağız genişliği / göz arası mesafe (stabil referans → gülümseme ağzı genişletir).
    /// Width/height yerine bunu kullanıyoruz: gülümseme dişlerle ağzı AÇABİLDİĞİ için yükseklik de
    /// artar ve oran ayrışmaz. Ham oran döner (nötr ~1.0, gülümseme ~1.2+); kalibrasyon SmileDetector'da.
    private func smileSpread(_ landmarks: VNFaceLandmarks2D?, leftEye: CGPoint?, rightEye: CGPoint?,
                             imageSize: CGSize, faceBox: CGRect) -> Float {
        let lips = topLeftPoints(landmarks?.outerLips, imageSize: imageSize)
        guard lips.count >= 4 else { return 0 }
        let xs = lips.map(\.x)
        let mouthWidth = (xs.max() ?? 0) - (xs.min() ?? 0)
        let ref: CGFloat
        if let l = leftEye, let r = rightEye {
            let dx = r.x - l.x, dy = r.y - l.y
            ref = (dx * dx + dy * dy).squareRoot()
        } else {
            ref = faceBox.width * 0.5
        }
        guard ref > 1 else { return 0 }
        return Float(mouthWidth / ref)
    }
}
