import SwiftUI

/// Liveness ekranı — Android `LivenessActivity` UI portu (SwiftUI). Kamera önizlemesi + jest
/// talimatları + timer + canlı % + başarısızlık özeti (chip vs selfie + skor, Retry/Cancel).
///
/// `onSuccess(alignedSelfieJPEG, matchScore)` başarıyla biter; `onCancel` iptalde. Aşama 4 gerçek
/// Register akışında da bu View kullanılacak (şimdilik dev test ekranından sürülür).
struct LivenessView: View {
    @StateObject private var viewModel: LivenessViewModel
    @ObservedObject private var camera: CameraController

    let onSuccess: (Data, Float) -> Void
    let onCancel: () -> Void

    init(viewModel: LivenessViewModel,
         onSuccess: @escaping (Data, Float) -> Void,
         onCancel: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _camera = ObservedObject(wrappedValue: viewModel.camera)
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            if camera.permissionDenied || camera.configurationFailed {
                permissionOverlay
            } else {
                overlays
            }

            if case .failure(let timeout) = viewModel.phase {
                failureDialog(timeout: timeout)
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.phase) { phase in
            if phase == .success, let jpeg = viewModel.alignedSelfieJPEG {
                onSuccess(jpeg, viewModel.finalMatchScore)
            }
        }
    }

    // MARK: - Overlays

    private var overlays: some View {
        VStack {
            // Üst bar: adım + timer
            HStack {
                Text(viewModel.stepText)
                    .font(.headline)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Capsule())
                Spacer()
                Text(viewModel.timerText)
                    .font(.headline.monospacedDigit())
                    .padding(8)
                    .frame(minWidth: 44)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding()

            Spacer()

            // Talimat / ✅ / yanlış hareket
            Group {
                if viewModel.checkmark {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                } else if viewModel.wrongMove {
                    VStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.red)
                        Text("Yanlış hareket — baştan")
                            .foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 6) {
                        Text(viewModel.instruction)
                            .font(.system(size: 26, weight: .bold))
                        Text(viewModel.subInstruction)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal)
            .multilineTextAlignment(.center)

            Spacer()

            // Alt: canlı % + chip küçük resim
            if viewModel.showScore {
                HStack(spacing: 12) {
                    if let chip = viewModel.chipPreview {
                        Image(uiImage: chip)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.4)))
                    }
                    Text("%\(viewModel.liveScorePercent)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(scoreColor)
                }
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 24)
            }
        }
    }

    private var scoreColor: Color {
        viewModel.liveScorePercent >= Int(LivenessViewModel.matchThreshold * 100) ? .green : .red
    }

    private var permissionOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill").font(.system(size: 48)).foregroundStyle(.white)
            Text("Kamera erişimi gerekli")
                .font(.headline).foregroundStyle(.white)
            Text("Ayarlar → VerifyBlind → Kamera'yı etkinleştirin.")
                .font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            Button("Kapat") { onCancel() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Başarısızlık özeti (Android dialog_biometric_fail)

    private func failureDialog(timeout: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: timeout ? "clock.badge.exclamationmark" : "person.crop.circle.badge.xmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(timeout ? "Süre doldu" : "Doğrulama tamamlanamadı")
                    .font(.headline)

                if !timeout, viewModel.showScore {
                    HStack(spacing: 16) {
                        thumb(viewModel.chipPreview, label: "Çip")
                        thumb(viewModel.selfiePreview, label: "Selfie")
                    }
                    Text("%\(Int(viewModel.finalMatchScore * 100))")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(viewModel.finalMatchScore >= LivenessViewModel.matchThreshold ? .green : .red)
                }

                HStack(spacing: 12) {
                    Button("İptal") { onCancel() }
                        .buttonStyle(.bordered)
                    Button("Tekrar Dene") { viewModel.retry() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
        }
    }

    private func thumb(_ image: UIImage?, label: String) -> some View {
        VStack(spacing: 4) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.gray.opacity(0.3))
                    .frame(width: 80, height: 80)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
