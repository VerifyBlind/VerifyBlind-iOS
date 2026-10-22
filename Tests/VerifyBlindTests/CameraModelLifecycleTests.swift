import XCTest
import SwiftUI
import AVFoundation
@testable import VerifyBlind

/// Kamera ekranlarındaki iki donmanın sözleşmesi.
///
/// - IOS-4H (5 sn): `MLModel(contentsOf:)` ana iş parçacığında ANE derlemesi yapıyordu; üstelik
///   `LivenessViewModel` çağıranın SwiftUI `body`'sinde her değerlendirmede yeniden kuruluyordu.
/// - IOS-3R (10-53 sn): çalışan oturuma bağlı önizleme katmanı ana iş parçacığında serbest kalınca
///   oturumu yeniden yapılandırıp medya sunucusunu bekliyordu.
final class CameraModelLifecycleTests: XCTestCase {

    // MARK: - FaceEmbedder: arka plan yüklemesi

    func testInitDoesNotWaitForModelLoad() {
        let release = DispatchSemaphore(value: 0)
        let embedder = FaceEmbedder(load: {
            release.wait()          // yükleme "uzun sürüyor"
            return nil
        })
        // init yükleyiciyi beklemeden döndü → hâlâ yükleniyor.
        XCTAssertEqual(embedder.state, .loading)
        XCTAssertTrue(embedder.isLoading)
        XCTAssertFalse(embedder.isAvailable)
        release.signal()
        XCTAssertTrue(embedder.waitUntilResolved(timeout: 5))
    }

    func testLoaderRunsOffMainThread() {
        let ran = expectation(description: "yükleyici koştu")
        var onMain = true
        let embedder = FaceEmbedder(load: {
            onMain = Thread.isMainThread
            ran.fulfill()
            return nil
        })
        wait(for: [ran], timeout: 5)
        XCTAssertFalse(onMain, "model yüklemesi ana iş parçacığında koşmamalı")
        XCTAssertTrue(embedder.waitUntilResolved(timeout: 5))
    }

    /// Hazır olmadan gelen kare: model hiç yokmuş gibi nil — mevcut "graceful" yol.
    func testEmbeddingIsNilWhileLoading() throws {
        let release = DispatchSemaphore(value: 0)
        let embedder = FaceEmbedder(load: { release.wait(); return nil })
        XCTAssertNil(embedder.embedding(from: try Self.grayImage()))
        release.signal()
        embedder.waitUntilResolved(timeout: 5)
    }

    func testMissingModelResolvesToUnavailable() throws {
        let embedder = FaceEmbedder(load: { nil })
        XCTAssertTrue(embedder.waitUntilResolved(timeout: 5))
        XCTAssertEqual(embedder.state, .unavailable)
        XCTAssertFalse(embedder.isLoading)
        XCTAssertNil(embedder.embedding(from: try Self.grayImage()))
    }

    func testWaitTimesOutWhileStillLoading() {
        let release = DispatchSemaphore(value: 0)
        let embedder = FaceEmbedder(load: { release.wait(); return nil })
        XCTAssertFalse(embedder.waitUntilResolved(timeout: 0.1))
        release.signal()
        XCTAssertTrue(embedder.waitUntilResolved(timeout: 5))
    }

    /// Gerçek bundle modeli arka planda çözülmeli (yüklendi ya da yok) ve kilitlenmemeli.
    func testBundledModelResolvesInBackground() throws {
        let embedder = FaceEmbedder(load: FaceEmbedder.loadBundledModel)
        XCTAssertTrue(embedder.waitUntilResolved(timeout: 60))
        XCTAssertNotEqual(embedder.state, .loading)
        if embedder.state == .ready {
            let emb = embedder.embedding(from: try Self.grayImage())
            XCTAssertEqual(emb?.count, FaceEmbedder.embeddingSize)
        }
    }

    // MARK: - LivenessView: VM yalnız ilk kurulumda üretilir

    /// Görünüm yapısını kurmak VM'i KURMAMALI: SwiftUI `body`'yi her değerlendirdiğinde
    /// `LivenessView(viewModel: LivenessViewModel(...))` ifadesi yeniden çalışıyor; VM ancak
    /// `StateObject` ilk kez kurulduğunda üretilmeli.
    func testLivenessViewInitDoesNotBuildViewModel() {
        var built = 0
        func make() -> LivenessViewModel {
            built += 1
            return LivenessViewModel(events: [], chipPhotoData: nil, isDemo: true)
        }
        for _ in 0..<3 {
            _ = LivenessView(viewModel: make(), onSuccess: { _, _, _, _ in }, onCancel: {})
        }
        XCTAssertEqual(built, 0)
    }

    // MARK: - Önizleme sökümü

    /// Söküm, katmanın session referansını hemen KOPARMAZ: önce oturum kendi kuyruğunda durur,
    /// sonra ana kuyrukta koparılır. Görünüm o ana kadar controller'da tutulur.
    func testRetirePreviewDetachesSessionAfterSessionQueue() {
        let camera = CameraController(position: .front)
        var view: CameraPreview.PreviewView? = CameraPreview.PreviewView()
        weak var weakView = view
        let layer = view!.videoPreviewLayer
        layer.session = camera.session

        camera.retirePreview(view!)
        view = nil
        XCTAssertNotNil(weakView, "görünüm oturum durana dek tutulmalı")
        XCTAssertTrue(layer.session === camera.session, "koparma eşzamanlı olmamalı")

        let detached = expectation(description: "session koparıldı")
        func poll() {
            if layer.session == nil { detached.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [detached], timeout: 5)
        XCTAssertFalse(camera.isRunning)
    }

    // MARK: - Yardımcı

    private static func grayImage(size: Int = FaceEmbedder.inputSize) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try XCTUnwrap(ctx.makeImage())
    }
}
