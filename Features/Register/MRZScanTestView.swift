import SwiftUI

/// Aşama 3 dev test ekranı — MRZ kamera taraması. Gerçek kimlik/pasaport arka yüzünden
/// Belge No / Doğum / Son Geçerlilik okur (NFC'yi sürecek alanlar). NFCTestView kalıbında.
///
/// PII: Belge No yalnızca EKRANDA gösterilir; Sentry'e GİTMEZ (`Log.sensitive` private).
struct MRZScanTestView: View {
    @StateObject private var camera = CameraController(position: .back)
    @State private var scanner = MRZScanner()
    @State private var result: MRZParser.Result?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            if camera.permissionDenied || camera.configurationFailed {
                cameraErrorOverlay
            } else {
                VStack {
                    Text("MRZ alanını (kartın arka yüzü) çerçeveye getirin")
                        .font(.footnote).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Capsule())
                        .padding(.top)

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.8), lineWidth: 2)
                        .frame(height: 120)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                    Spacer()

                    if let result {
                        resultCard(result)
                    }
                }
            }
        }
        .navigationTitle("Aşama 3 — MRZ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            scanner.onResult = { r in
                result = r
                camera.stop()
                Log.info("MRZ test OK: type=\(r.documentType) dobLen=\(r.dateOfBirth.count) expLen=\(r.dateOfExpiry.count)", category: .nfc)
                Log.sensitive("MRZ docNo", value: r.documentNumber, category: .nfc)
            }
            camera.onFrame = { buffer, orientation in
                scanner.process(buffer, orientation: orientation)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    private func resultCard(_ r: MRZParser.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("MRZ okundu", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
            Text("Belge No: \(r.documentNumber)").font(.footnote.monospaced())
            Text("Doğum: \(r.dateOfBirth)").font(.footnote.monospaced())
            Text("Son Geçerlilik: \(r.dateOfExpiry)").font(.footnote.monospaced())
            Text("Tip: \(r.documentType)").font(.footnote.monospaced())
            Button("Tekrar Tara") {
                result = nil
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

    private var cameraErrorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 40)).foregroundStyle(.white)
            Text("Kamera erişimi gerekli").foregroundStyle(.white)
            Text("Ayarlar → VerifyBlind → Kamera").font(.footnote).foregroundStyle(.white.opacity(0.8))
        }
    }
}
