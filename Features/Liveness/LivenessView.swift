import SwiftUI

/// Liveness ekranı — Android `LivenessActivity` UI'ının BİREBİR portu (SwiftUI).
/// Beyaz zemin + ortada OVAL kamera penceresi; kenarlık aynı zamanda AKTİF HAREKETİN kalan süre
/// halkasıdır (rakamlı sayaç yok). Üstte adım (siyah, ortada) + gri üst ipucu + talimat, altta gri
/// alt ipucu + sol-altta çip küçük resmi ve canlı %. (b) ışık uyarısı: `viewModel.qualityWarning`.
///
/// `onSuccess(alignedSelfieJPEG, antiSpoofCropJPEG, matchScore)` başarıyla biter; `onCancel` iptalde.
/// Canlılık koşusundan geri bildirim kutusuna taşınan teşhis paketi.
///
/// İki parça, iki ayrı rejim: `summary` skalerdir (skor, luma, açı, adım) ve rıza gerektirmez;
/// `chipAlignedPNG` ise görüntüdür ve kullanıcı AYRI bir anahtarı açmadıkça hiçbir yere gitmez.
struct LivenessDiagnostics {
    let chipAlignedPNG: Data?
    let summary: String
    /// En iyi cihaz-içi eşleşme skoru, 0-100 tamsayı. `summary` içinde metin olarak da var ama
    /// huniye SAYI gitmesi gerekiyor — metinden ayrıştırmak kırılgan olurdu.
    let matchScorePercent: Int
}

struct LivenessView: View {
    @StateObject private var viewModel: LivenessViewModel
    @ObservedObject private var camera: CameraController

    let onSuccess: (Data, Data?, Float, LivenessDiagnostics) -> Void
    let onCancel: () -> Void
    /// Canlılık testi başarısız bitti — huni "canlılık adımını NEDEN kaybettik" sorusunu buradan
    /// yanıtlar. İkinci parametre reddedilen karedir (varsa): geri bildirim kutusu bunu ancak
    /// kullanıcı işaretlerse eke koyar. Üçüncüsü teşhis paketi (çip kırpımı + skaler ölçüler).
    var onFailure: ((LivenessViewModel.FailureReason, Data?, LivenessDiagnostics) -> Void)?

    // Liveness boyunca ekran parlaklığını sonuna kadar açıp çıkışta eski değere döndürmek için
    // saklanan orijinal parlaklık (Android `originalBrightness` paritesi). iOS'ta yalnız değer
    // yedeklenip geri yüklenir (oto-parlaklık aç/kapa durumunu sorgulayan public API yok).
    @State private var savedBrightness: CGFloat?

    // Android renkleri (LivenessActivity / FaceOvalOverlayView)
    private let redColor  = Color(red: 1.0,   green: 0.267, blue: 0.267) // #FF4444
    private let grayColor = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555

    init(viewModel: LivenessViewModel,
         onSuccess: @escaping (Data, Data?, Float, LivenessDiagnostics) -> Void,
         onCancel: @escaping () -> Void,
         onFailure: ((LivenessViewModel.FailureReason, Data?, LivenessDiagnostics) -> Void)? = nil) {
        self.onFailure = onFailure
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

            if case .failure(let reason) = viewModel.phase {
                failureDialog(reason: reason)
            }
        }
        .statusBar(hidden: true)   // Android gibi tam ekran — durum çubuğu gizli
        .onAppear {
            // Ekran ışığını yedekle → sonuna kadar aç (ön kamera yüz aydınlatması). Ekran uykusunu
            // engelle (liveness boyunca otomatik kısılma/uyku olmasın). Android paritesi.
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            if let b = savedBrightness { UIScreen.main.brightness = b }
        }
        .onChange(of: viewModel.phase) { phase in
            let diagnostics = LivenessDiagnostics(chipAlignedPNG: viewModel.alignedChipPNG,
                                                  summary: viewModel.diagnosticsSummary,
                                                  matchScorePercent: Int(viewModel.finalMatchScore * 100))
            if phase == .success, let jpeg = viewModel.alignedSelfieJPEG {
                onSuccess(jpeg, viewModel.antiSpoofCropJPEG, viewModel.finalMatchScore, diagnostics)
            }
            if case .failure(let reason) = phase { onFailure?(reason, viewModel.diagnosticJPEG, diagnostics) }
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
                // Kalan süre halkası: oval kenarlığın KENDİSİ erir. Rakam gösterilmez — sayaç
                // baskı kuruyor ve kafa çevrikken zaten görünmüyor; erimekte olan bir kenarlık
                // "devam et" der. Son ~4 saniyede kehribara döner (+ sessiz haptic dürtme).
                Ellipse()
                    .stroke(Color(white: 0.88), lineWidth: 3)
                    .frame(width: ovalW, height: ovalH)
                Ellipse()
                    .trim(from: 0, to: viewModel.gestureProgress)
                    .stroke(timeRingColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: ovalW, height: ovalH)
                    .animation(.linear(duration: 0.1), value: viewModel.gestureProgress)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }

    // MARK: - Metin + canlı durum katmanları

    private var overlays: some View {
        VStack(spacing: 0) {
            // Üst: adım sayacı (ortada, siyah). Kalan süre RAKAMLA değil, oval kenarlıktaki
            // halkayla gösterilir.
            // Boşken "1/5" yazmak YANLIŞ bilgi: `presentChallenge` hiç koşmamışken bile ekranda ilk
            // adım duruyormuş gibi görünüyor. 2026-08-25 teşhisinde tam olarak bunu yanlış okuduk —
            // üstteki sayı komutun geldiğine kanıt sanıldı. Komut yoksa burası da boş kalsın.
            Text(viewModel.stepText)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.black)
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
                    Text(viewModel.wrongMoveDetail.isEmpty
                         ? L.t("liveness_wrong_move") : viewModel.wrongMoveDetail)
                        .foregroundColor(redColor)
                }
            } else {
                VStack(spacing: 6) {
                    Text(viewModel.instruction)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.black)
                    if !viewModel.subInstruction.isEmpty {
                        Text(viewModel.subInstruction)
                            .font(.system(size: 14))
                            .foregroundColor(grayColor)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    /// Kalan süre halkasının rengi — son ~4 saniyede kehribar.
    private var timeRingColor: Color {
        viewModel.gestureProgress <= LivenessViewModel.lowTimeFraction
            ? Color(red: 0.95, green: 0.61, blue: 0.07) : redColor
    }

    private static func failureIcon(_ reason: LivenessViewModel.FailureReason) -> String {
        switch reason {
        case .gestureTimeout, .sessionTimeout: return "clock.badge.exclamationmark"
        case .tooManyErrors: return "exclamationmark.triangle"
        case .noSelfie:      return "camera.badge.ellipsis"
        case .matchFailed:   return "person.crop.circle.badge.xmark"
        }
    }

    private static func failureTitleKey(_ reason: LivenessViewModel.FailureReason) -> String {
        switch reason {
        case .gestureTimeout, .sessionTimeout: return "liveness_timeout_title"
        case .tooManyErrors: return "liveness_too_many_errors_title"
        case .noSelfie:      return "liveness_selfie_error_title"
        case .matchFailed:   return "liveness_match_failed_title"
        }
    }

    private static func failureMessageKey(_ reason: LivenessViewModel.FailureReason) -> String {
        switch reason {
        case .gestureTimeout, .sessionTimeout: return "liveness_timeout_message"
        case .tooManyErrors: return "liveness_too_many_errors_message"
        case .noSelfie:      return "liveness_selfie_error_message"
        case .matchFailed:   return "liveness_match_failed_message"
        }
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
            Text(L.t("liveness_camera_permission_title"))
                .font(.headline).foregroundColor(.black)
            Text(L.t("liveness_camera_permission_body"))
                .font(.footnote).foregroundColor(grayColor).multilineTextAlignment(.center)
            Button(L.t("btn_close")) { onCancel() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Başarısızlık özeti (Android dialog_biometric_fail)

    private func failureDialog(reason: LivenessViewModel.FailureReason) -> some View {
        let showThumbs = (reason == .matchFailed) && viewModel.showScore
        return ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: Self.failureIcon(reason))
                    .font(.system(size: 44))
                    .foregroundColor(.orange)
                Text(L.t(Self.failureTitleKey(reason)))
                    .font(.headline)
                Text(L.t(Self.failureMessageKey(reason)))
                    .font(.footnote)
                    .foregroundColor(grayColor)
                    .multilineTextAlignment(.center)

                if showThumbs {
                    HStack(spacing: 16) {
                        thumb(viewModel.chipPreview, label: L.t("liveness_thumb_chip"))
                        thumb(viewModel.selfiePreview, label: L.t("liveness_thumb_selfie"))
                    }
                    Text("\(Int(viewModel.finalMatchScore * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundColor(viewModel.finalMatchScore >= LivenessViewModel.matchThreshold ? .green : redColor)
                }

                HStack(spacing: 12) {
                    Button(L.t("btn_cancel")) { onCancel() }
                        .buttonStyle(.bordered)
                    Button(L.t("btn_retry")) { viewModel.retry() }
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
