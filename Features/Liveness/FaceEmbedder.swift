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
///
/// **Yükleme ana iş parçacığında YAPILMAZ** (IOS-4H: `MLModel(contentsOf:)` ANE derlemesiyle ana
/// iş parçacığını 5 sn kilitledi; ViewModel SwiftUI `body` içinde kuruluyordu). Model süreç başına
/// BİR KEZ, arka planda yüklenir (`shared`) ve canlılık/giriş ekranları arasında paylaşılır.
/// Yükleme bitmeden gelen çağrılar, model hiç yokmuş gibi `nil` döner — mevcut "graceful" yol.
final class FaceEmbedder {

    static let embeddingSize = 192
    static let inputSize = 112

    /// Süreç geneli örnek — ilk erişimde arka plan yüklemesini başlatır, çağıranı bloklamaz.
    static let shared = FaceEmbedder()

    /// Akış başlarken çağrılır: model, kullanıcı yüz adımına gelene kadar hazır olsun.
    static func preload() { _ = shared }

    /// Yüklenmiş model + girdi sözleşmesi.
    struct LoadedModel {
        let model: MLModel
        let inputName: String
        let inputIsImage: Bool
    }

    enum State: Equatable {
        case loading
        case ready
        /// Model bundle'da yok ya da yüklenemedi — kalıcı; embedding çağrıları `nil` döner.
        case unavailable
    }

    private let lock = NSLock()
    private let predictionLock = NSLock()
    private var loaded: LoadedModel?
    private var _state: State = .loading
    private let resolved = DispatchGroup()

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Yükleme sürüyor mu? Kare döngüsü buna bakıp referans gömmesini erteler.
    var isLoading: Bool { state == .loading }

    /// Model kullanılabilir mi (yüklendi). Yükleme sürerken de `false`.
    var isAvailable: Bool { state == .ready }

    /// - Parameter load: arka planda koşan yükleyici. Testler sahte yükleyici verir.
    init(load: @escaping () -> LoadedModel? = FaceEmbedder.loadBundledModel,
         queue: DispatchQueue = .global(qos: .userInitiated)) {
        resolved.enter()
        queue.async { [self] in
            let result = load()
            lock.lock()
            loaded = result
            _state = result == nil ? .unavailable : .ready
            lock.unlock()
            resolved.leave()
        }
    }

    /// Yükleme çözülene (hazır ya da yok) kadar bekler. ANA İŞ PARÇACIĞINDA ÇAĞIRMA — yalnız video
    /// kuyruğunda, koşu bittikten sonra kapı değerlendirilirken kullanılır. Süre dolarsa `false`.
    @discardableResult
    func waitUntilResolved(timeout: TimeInterval) -> Bool {
        resolved.wait(timeout: .now() + timeout) == .success
    }

    /// Bundle'daki `MobileFaceNet.mlmodelc`'yi yükler (arka plan kuyruğu).
    static func loadBundledModel() -> LoadedModel? {
        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") else {
            Log.warning("FaceEmbedder: MobileFaceNet.mlmodelc bundle'da yok — canlı % devre dışı.", category: .liveness)
            return nil
        }
        do {
            let startedAt = Date()
            let m = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            // Girdi adı + tipi dinamik okunur (dönüşüm çıktı adları değişebilir).
            let inputs = m.modelDescription.inputDescriptionsByName
            guard let input = inputs.first(where: { $0.value.type == .image }) ?? inputs.first else {
                Log.error("FaceEmbedder: modelin girdisi yok", category: .liveness)
                return nil
            }
            let isImage = input.value.type == .image
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.info("FaceEmbedder: model yüklendi (input=\(input.key), image=\(isImage), \(ms) ms, arka plan).",
                     category: .liveness)
            return LoadedModel(model: m, inputName: input.key, inputIsImage: isImage)
        } catch {
            Log.error("FaceEmbedder: model yüklenemedi", error: error, category: .liveness)
            return nil
        }
    }

    /// Hizalanmış 112×112 görüntüden L2-normalize edilmiş 192-dim embedding. Model yoksa ya da
    /// henüz yükleniyorsa nil.
    func embedding(from image: CGImage) -> [Float]? {
        lock.lock()
        let current = loaded
        lock.unlock()
        guard let current, current.inputIsImage else { return nil }
        guard let pixelBuffer = Self.makePixelBuffer(from: image, size: Self.inputSize) else { return nil }

        do {
            let featureValue = MLFeatureValue(pixelBuffer: pixelBuffer)
            let provider = try MLDictionaryFeatureProvider(dictionary: [current.inputName: featureValue])
            // Örnek artık paylaşılıyor: tahminler sıraya sokulur (kare başına en çok bir çağrı).
            predictionLock.lock()
            defer { predictionLock.unlock() }
            let output = try current.model.prediction(from: provider)

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
