import CoreML
import CoreVideo
import CoreGraphics
import Foundation

/// Cihaz-içi yüz embedding'i (CoreML) — Android `util/FaceEmbedder` (TFLite) portu.
///
/// `MobileFaceNet.mlmodelc`'yi bundle'dan DİNAMİK yükler (generated sınıf DEĞİL) → model henüz
/// commit'lenmediyse `nil` döner ve canlı % nazikçe gizlenir (Android `chipEmbedding == null`
/// yolunun aynısı; liveness yine çalışır). Model = `mobilefacenet.tflite`'ın CoreML dönüşümü
/// (bkz. `Tools/convert_mobilefacenet_to_coreml.ipynb`).
///
/// Dönüşüm sözleşmesi: 112×112 RGB **image** girdisi, normalizasyon ((p−127.5)/128) modele
/// scale/bias ile gömülü; çıktı = 192-dim ham embedding (uygulama L2-normalize eder, Android
/// `runInference` paritesi). CoreML = sistem framework → SPM bağımlılığı yok.
final class FaceEmbedder {

    static let embeddingSize = 192
    static let inputSize = 112

    private let model: MLModel?
    private let inputName: String?
    private let inputIsImage: Bool

    /// Model bundle'da yoksa `isAvailable == false` ve tüm embedding çağrıları `nil` döner.
    var isAvailable: Bool { model != nil }

    init() {
        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") else {
            self.model = nil
            self.inputName = nil
            self.inputIsImage = false
            Log.warning("FaceEmbedder: MobileFaceNet.mlmodelc bundle'da yok — canlı % devre dışı.", category: .liveness)
            return
        }
        do {
            let config = MLModelConfiguration()
            let m = try MLModel(contentsOf: url, configuration: config)
            self.model = m
            // Girdi adı + tipi dinamik okunur (dönüşüm çıktı adları değişebilir).
            let inputs = m.modelDescription.inputDescriptionsByName
            if let imageInput = inputs.first(where: { $0.value.type == .image }) {
                self.inputName = imageInput.key
                self.inputIsImage = true
            } else if let first = inputs.first {
                self.inputName = first.key
                self.inputIsImage = false
            } else {
                self.inputName = nil
                self.inputIsImage = false
            }
            Log.info("FaceEmbedder: model yüklendi (input=\(inputName ?? "?"), image=\(inputIsImage)).", category: .liveness)
        } catch {
            self.model = nil
            self.inputName = nil
            self.inputIsImage = false
            Log.error("FaceEmbedder: model yüklenemedi", error: error, category: .liveness)
        }
    }

    /// Hizalanmış 112×112 görüntüden L2-normalize edilmiş 192-dim embedding. Model yoksa nil.
    func embedding(from image: CGImage) -> [Float]? {
        guard let model, let inputName, inputIsImage else { return nil }
        guard let pixelBuffer = Self.makePixelBuffer(from: image, size: inputSize) else { return nil }

        do {
            let featureValue = MLFeatureValue(pixelBuffer: pixelBuffer)
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: featureValue])
            let output = try model.prediction(from: provider)

            // İlk MLMultiArray çıktısını al (çıktı adı dönüşüme göre değişebilir).
            guard let outName = output.featureNames.first(where: {
                output.featureValue(for: $0)?.multiArrayValue != nil
            }), let array = output.featureValue(for: outName)?.multiArrayValue else {
                return nil
            }

            var raw = [Float](repeating: 0, count: array.count)
            for i in 0..<array.count { raw[i] = array[i].floatValue }
            return Self.l2Normalize(raw)
        } catch {
            Log.error("FaceEmbedder: inference hatası", error: error, category: .liveness)
            return nil
        }
    }

    // MARK: - Saf yardımcılar

    /// L2 normalizasyon — Android `runInference` sonu (norm>0 ise böl).
    static func l2Normalize(_ v: [Float]) -> [Float] {
        let sumSq = v.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Kosinüs benzerliği — Android `FaceEmbedder.cosineSimilarity` ile birebir.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - CGImage → CVPixelBuffer (112×112 BGRA)

    private static func makePixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}
