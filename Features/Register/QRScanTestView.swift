#if DEBUG
import SwiftUI

/// Aşama 3 dev test ekranı — QR/DataMatrix kamera taraması. Partner login nonce QR'ı (Aşama 4)
/// için kullanılacak tarayıcıyı doğrular. Okunan payload ekranda gösterilir.
struct QRScanTestView: View {
    @StateObject private var camera = CameraController(position: .back)
    @State private var scanner = QRScanner()
    @State private var payload: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            if camera.permissionDenied || camera.configurationFailed {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill").font(.system(size: 40)).foregroundStyle(.white)
                    Text("Kamera erişimi gerekli").foregroundStyle(.white)
                }
            } else {
                VStack {
                    Text("QR kodu çerçeveye getirin")
                        .font(.footnote).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Capsule())
                        .padding(.top)

                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 220, height: 220)
                        .padding(.top, 32)

                    Spacer()

                    if let payload {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("QR okundu", systemImage: "qrcode.viewfinder")
                                .font(.headline).foregroundStyle(.green)
                            Text("Uzunluk: \(payload.count)").font(.footnote.monospaced())
                            Text(payload.prefix(80) + (payload.count > 80 ? "…" : ""))
                                .font(.caption.monospaced())
                                .lineLimit(4)
                            Button("Tekrar Tara") {
                                self.payload = nil
                                scanner.reset()
                                camera.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                }
            }
        }
        .navigationTitle("Aşama 3 — QR")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            scanner.onResult = { value in
                payload = value
                camera.stop()
                Log.info("QR test OK: len=\(value.count)", category: .flow)
            }
            camera.onFrame = { buffer, orientation in
                scanner.process(buffer, orientation: orientation)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}
#endif
