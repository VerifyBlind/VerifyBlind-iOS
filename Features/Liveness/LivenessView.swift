import SwiftUI

/// Liveness ekranı — Android `LivenessActivity` UI'ının BİREBİR portu (SwiftUI).
/// Beyaz zemin + ortada OVAL kamera penceresi (kırmızı kenarlık + kesik kılavuz çizgileri),
/// üstte adım (siyah, ortada) + timer (kırmızı, sağ) + gri üst ipucu + talimat, altta gri
/// alt ipucu + sol-altta çip küçük resmi ve canlı %. (b) ışık uyarısı: `viewModel.qualityWarning`.
///
/// `onSuccess(alignedSelfieJPEG, matchScore)` başarıyla biter; `onCancel` iptalde.
struct LivenessView: View {
    @StateObject private var viewModel: LivenessViewModel
    @ObservedObject private var camera: CameraController

    let onSuccess: (Data, Float) -> Void
    let onCancel: () -> Void

    // Android renkleri (LivenessActivity / FaceOvalOverlayView)
    private let redColor  = Color(red: 1.0,   green: 0.267, blue: 0.267) // #FF4444
    private let grayColor = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555

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
            Color.white.ignoresSafeArea()   // Android: beyaz zemin

            if camera.permissionDenied || camera.configurationFailed {
                permissionOverlay
            } else {
                ovalCamera     // oval kamera penceresi (Android FaceOvalOverlayView)
                overlays       // metinler + canlı durum
                backButton     // sol-üst geri (iOS'ta sistem geri tuşu yok)
            }

            if case .failure(let timeout) = viewModel.phase {
                failureDialog(timeout: timeout)
            }
        }
        .statusBar(hidden: true)   // Android gibi tam ekran — durum çubuğu gizli
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.phase) { phase in
            if phase == .success, let jpeg = viewModel.alignedSelfieJPEG {
                onSuccess(jpeg, viewModel.finalMatchScore)
            }
        }
    }

    // MARK: - Oval kamera penceresi (beyaz zemin üzerinde oval kesit, kırmızı kenarlık)

    private var ovalCamera: some View {
        GeometryReader { geo in
            let ovalW = geo.size.width * 0.75
            let ovalH = ovalW * 1.35
            ZStack {
                CameraPreview(session: camera.session)
                    .frame(width: ovalW, height: ovalH)
                    .clipShape(Ellipse())
                Ellipse()
                    .stroke(redColor, lineWidth: 3)
                    .frame(width: ovalW, height: ovalH)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }

    // MARK: - Metin + canlı durum katmanları

    private var overlays: some View {
        VStack(spacing: 0) {
            // Üst: adım (ortada, siyah) + timer (sağ, kırmızı)
            ZStack {
                Text(viewModel.stepText.isEmpty ? "1/5" : viewModel.stepText)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.black)
                HStack {
                    Spacer()
                    Text(viewModel.timerText)
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundColor(redColor)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Üst ipucu (gri)
            Text(LocalizedStringKey("liveness_top_hint"))
                .font(.system(size: 14))
                .foregroundColor(grayColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            // Talimat (siyah, bold) / ✅ / yanlış hareket
            instructionBlock
                .padding(.top, 20)

            // (b) Işık uyarısı — kötü koşulda kırmızı label (Android tvQualityWarning)
            if let warning = viewModel.qualityWarning {
                Text(warning)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(Color(red: 0.93, green: 0.23, blue: 0.23).opacity(0.85))
                    .cornerRadius(8)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer()

            // Alt ipucu (gri) — eşik %'si ile
            Text(String(format: NSLocalizedString("liveness_threshold_hint", comment: ""),
                        Int(LivenessViewModel.matchThreshold * 100)))
                .font(.system(size: 13))
                .foregroundColor(grayColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            // Sol-alt: çip küçük resim + canlı % (Android layoutLiveStatus)
            if viewModel.showScore {
                HStack(spacing: 12) {
                    if let chip = viewModel.chipPreview {
                        Image(uiImage: chip)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 60, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("\(viewModel.liveScorePercent)%")
                        .font(.system(size: 18, weight: .bold).monospacedDigit())
                        .foregroundColor(scoreColor)
                    Spacer()
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
    }

    private var instructionBlock: some View {
        Group {
            if viewModel.checkmark {
                Text("✅").font(.system(size: 40))
            } else if viewModel.wrongMove {
                VStack(spacing: 6) {
                    Text("⚠️").font(.system(size: 34))
                    Text("Yanlış hareket — baştan").foregroundColor(redColor)
                }
            } else {
                Text(viewModel.instruction)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private var scoreColor: Color {
        viewModel.liveScorePercent >= Int(LivenessViewModel.matchThreshold * 100) ? .green : redColor
    }

    // Sol-üst geri butonu — iOS'ta sistem geri tuşu yok; az dikkat çeken, yuvarlak.
    private var backButton: some View {
        VStack {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(grayColor)
                        .frame(width: 38, height: 38)
                        .background(Color(white: 0.93).opacity(0.85), in: Circle())
                }
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    private var permissionOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill").font(.system(size: 48)).foregroundColor(grayColor)
            Text("Kamera erişimi gerekli")
                .font(.headline).foregroundColor(.black)
            Text("Ayarlar → VerifyBlind → Kamera'yı etkinleştirin.")
                .font(.footnote).foregroundColor(grayColor).multilineTextAlignment(.center)
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
                    .foregroundColor(.orange)
                Text(timeout ? "Süre doldu" : "Doğrulama tamamlanamadı")
                    .font(.headline)

                if !timeout, viewModel.showScore {
                    HStack(spacing: 16) {
                        thumb(viewModel.chipPreview, label: "Çip")
                        thumb(viewModel.selfiePreview, label: "Selfie")
                    }
                    Text("\(Int(viewModel.finalMatchScore * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundColor(viewModel.finalMatchScore >= LivenessViewModel.matchThreshold ? .green : redColor)
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
