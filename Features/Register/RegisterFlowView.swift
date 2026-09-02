import SwiftUI
import UIKit

/// Kayıt akışı ekranı — Android stepper + ViewFlipper (Hazırlık/MRZ/NFC/Liveness/İşlem/Başarı).
struct RegisterFlowView: View {
    let isDemo: Bool
    let onFinish: () -> Void

    @StateObject private var vm: RegisterViewModel

    // Yarıda kalan akışın ardından "bir sorun mu yaşadınız?" — yalnız HATA sonrası ve sıklık
    // sınırlı (bkz. FlowFeedbackPrompt).
    @State private var showFeedbackPrompt = false
    @State private var showFeedbackForm = false
    @State private var feedbackStep: FlowFeedbackPrompt.FlowStep?
    /// Kutu hata sonrası mı, yarıda bırakma sonrası mı açıldı — metin buna göre değişir.
    @State private var promptIsAbandonment = false

    init(isDemo: Bool, onFinish: @escaping () -> Void) {
        self.isDemo = isDemo
        // Kapanış TEK yerden sarmalanır: `onFinish` gövdede dört ayrı yerden çağrılıyor (başarı,
        // "hayır" cevabı, form kapanışı, yarıda çıkış) ve akış etiketini her birinde ayrı ayrı
        // temizlemek er ya da geç bir dalda unutulurdu.
        self.onFinish = {
            Task { await FlowTelemetry.shared.endFlow() }
            onFinish()
        }
        _vm = StateObject(wrappedValue: RegisterViewModel(isDemo: isDemo))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch vm.step {
            case .liveness:
                // Liveness tam ekran (Android ayrı LivenessActivity). Demo: sahte jest + chip yok.
                LivenessView(
                    viewModel: LivenessViewModel(
                        challenges: vm.isDemo ? [1, 2, 3] : vm.challenges,
                        chipPhotoData: vm.isDemo ? nil : vm.chipPhoto,
                        isDemo: vm.isDemo,
                        flowNonce: vm.flowNonce),
                    onSuccess: { selfie, crop, score, diag in
                        vm.onLiveness(selfie: selfie, antiSpoofCrop: crop, score: score, diagnostics: diag)
                    },
                    onCancel: leaveLiveness,
                    onFailure: { vm.onLivenessFailed($0, photo: $1, diagnostics: $2) }
                )
            case .processing:
                ProcessingStepView(showFlowSteps: true)
            case .success:
                SuccessStepView(onHome: onFinish)
            case .failed(let title, let message, let offersSettings):
                FailedStepView(title: title, message: message,
                               offersSettings: offersSettings, onClose: closeAfterFailure)
            case .biometricConsent:
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        header
                        StepperHeader(steps: [L.t("step_prepare"), L.t("step_mrz"), L.t("step_nfc"), L.t("step_face")], current: 4)
                        Spacer()
                    }
                    Color.black.opacity(0.5).ignoresSafeArea()
                    BiometricConsentSheet(
                        isDemo: vm.isDemo,
                        onApprove: { vm.approveBiometricConsent() },
                        onReject: leaveFlow
                    )
                    .transition(.move(edge: .bottom))
                }
            default:
                VStack(spacing: 0) {
                    header
                    StepperHeader(steps: [L.t("step_prepare"), L.t("step_mrz"), L.t("step_nfc"), L.t("step_face")],
                                  current: currentStepIndex)
                    stepContent
                }
            }
        }
        .alert(L.t(promptIsAbandonment ? "feedback_prompt_title_left" : "feedback_prompt_title"),
               isPresented: $showFeedbackPrompt) {
            Button(L.t("feedback_prompt_yes")) { showFeedbackForm = true }
            Button(L.t("feedback_prompt_no"), role: .cancel) { onFinish() }
        } message: {
            // Yarıda bırakan kişiye "bir sorun mu yaşadınız?" demek başarısızlık varsayar; oysa
            // telefonu çalmış da olabilir. Metin suçlayıcı değil, davetkâr olmalı.
            Text(L.t(promptIsAbandonment ? "feedback_prompt_message_left" : "feedback_prompt_message"))
        }
        .sheet(isPresented: $showFeedbackForm, onDismiss: onFinish) {
            FeedbackView(prefilledSubject: feedbackStep.map { FlowFeedbackPrompt.subject(for: $0) },
                         diagnosticPhoto: vm.diagnosticSelfie,
                         chipPhoto: vm.chipAlignedPhoto,
                         diagnostics: vm.livenessDiagnostics,
                         flowId: vm.flowId)
        }
    }

    /// Hata ekranı kapatılırken: uygunsa geri bildirim teklif et, değilse doğrudan çık.
    private func closeAfterFailure() {
        offerFeedback(step: vm.failedAtStep, isAbandonment: false)
    }

    /// Akıştan YARIDA çıkış (geri tuşu ya da biyometrik rızayı reddetme).
    ///
    /// Neden hatalı akış kadar önemli: bir hatayı sunucu zaten açıklıyor — kod, profil, skor
    /// elimizde. Yarıda bırakanlar hakkındaysa huninin "hangi adımda kaybettik" demesi dışında
    /// HİÇBİR şey bilmiyoruz; tek kaynak kullanıcının kendisi. Hazırlık ekranından geri dönene
    /// sorulmaz: henüz hiçbir şey denemedi.
    private func leaveFlow() {
        offerFeedback(step: abandonedStep, isAbandonment: true)
    }

    /// Canlılık ekranından çıkış — akıştan tamamen çıkarır (bkz. `onLivenessCancel`).
    ///
    /// Canlılık düştükten sonra "Vazgeç" diyen kişi sıradan bir vazgeçen değil: bir hatayla
    /// karşılaştı. Kutunun metni buna göre seçilir (Android `hadErrorInFlow` paritesi).
    private func leaveLiveness() {
        vm.onLivenessCancel()
        offerFeedback(step: abandonedStep, isAbandonment: !vm.livenessDidFail)
    }

    private func offerFeedback(step: FlowFeedbackPrompt.FlowStep?, isAbandonment: Bool) {
        // Demo akışı gerçek bir deneme değil — geri bildirim istatistiğini de kirletmemeli.
        guard !vm.isDemo, let step, FlowFeedbackPrompt.shouldOffer() else {
            onFinish()
            return
        }
        FlowFeedbackPrompt.markShown()   // "hayır" dese de sayaç işler — amaç sıklığı sınırlamak
        feedbackStep = step
        promptIsAbandonment = isAbandonment
        showFeedbackPrompt = true
    }

    /// Kullanıcının bıraktığı adım = ulaştığı EN İLERİ adım (anlık adım değil: liveness iptal
    /// edilince akış MRZ'ye düşüyor ve anlık adım vazgeçme noktasını yanlış gösterirdi).
    /// Hazırlığa kadar gelip geri dönen için nil → sorulmaz.
    private var abandonedStep: FlowFeedbackPrompt.FlowStep? { vm.furthestFlowStep }

    private var currentStepIndex: Int {
        switch vm.step {
        case .preparation: return 1
        case .mrz: return 2
        case .nfc: return 3
        default: return 4
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch vm.step {
        case .preparation:
            PreparationStepView(vm: vm)
        case .mrz:
            MRZScanStepView(isDemo: vm.isDemo, onResult: { vm.onMrz($0) })
        case .nfc:
            NfcStepView(
                status: vm.nfcStatus,
                isDemo: vm.isDemo,
                documentType: vm.documentType,
                retryMessage: vm.nfcRetryMessage,
                onStart: {
                    if vm.isDemo {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { vm.demoAfterNfc() }
                    } else {
                        vm.startNfc()
                    }
                },
                onRetry: { vm.retryNfc() }
            )
        default:
            EmptyView()
        }
    }

    /// Geri oku: önce BIR ADIM geri (NFC → MRZ, MRZ → Hazırlık); geri gidilecek adım
    /// kalmadıysa akıştan çık. Eskiden her adımda doğrudan çıkıyordu, yani NFC'de kartı
    /// okutamayan kullanıcı el sıkışma dahil her şeyi baştan yapıyordu.
    private func goBack() {
        if vm.stepBack() { return }
        leaveFlow()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "arrow.left").font(.system(size: 18)).foregroundColor(Theme.onSurface)
                    .frame(width: 40, height: 40)
            }
            Text(L.t("stepper_title_add_card"))
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onSurface)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }
}

// MARK: - Hazırlık

private struct PreparationStepView: View {
    @ObservedObject var vm: RegisterViewModel

    @State private var privacyDoc: PrivacyDoc? = nil
    @State private var loadingPrivacy = false

    private let tips: [(String, String, String)] = [
        ("sun.max", "tip1_title", "tip1_desc"),
        ("lightbulb", "tip2_title", "tip2_desc"),
        ("iphone", "tip3_title", "tip3_desc"),
        ("eyeglasses", "tip4_title", "tip4_desc"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L.t("prepare_title"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.onSurface)
                    .padding(.top, 8)
                Text(L.t("prepare_subtitle"))
                    .font(.system(size: 14))
                    .foregroundColor(Theme.onSurfaceVariant)

                ForEach(tips, id: \.0) { tip in
                    HStack(alignment: .top, spacing: 14) {
                        IconCircle(systemName: tip.0, fill: Theme.blueSoft, tint: Theme.themePrimary, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t(tip.1)).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.onSurface)
                            Text(L.t(tip.2)).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                        }
                        Spacer()
                    }
                }

                Spacer().frame(height: 8)

                // Aydınlatma Metni link (Android tvPrivacyNoticeCardAdd paritesi)
                Button {
                    fetchPrivacy()
                } label: {
                    if loadingPrivacy {
                        ProgressView().frame(height: 20)
                    } else {
                        Text(L.t("read_privacy_notice"))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.themePrimary)
                            .underline()
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)

                // KVKK onay kutusu
                Button { vm.kvkkAccepted.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: vm.kvkkAccepted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20))
                            .foregroundColor(vm.kvkkAccepted ? Theme.themePrimary : Theme.onSurfaceVariant)
                        Text(L.t("kvkk_consent_checkbox"))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.onSurface)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                PrimaryGradientButton(title: L.t("btn_start"),
                                      enabled: vm.kvkkAccepted && !vm.isStarting,
                                      loading: vm.isStarting) { vm.begin() }
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .sheet(item: $privacyDoc) { doc in PrivacyNoticeView(text: doc.text) }
        // Demo: KVKK onayını otomatik işaretle + 3sn sonra "Başla" (normal akış etkilenmez).
        // Hazırlık adımında değilsek (kullanıcı önceden ilerlediyse) geç tetik yok sayılır.
        .onAppear {
            guard vm.isDemo else { return }
            vm.kvkkAccepted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if vm.isDemo && vm.step == .preparation { vm.begin() }
            }
        }
    }

    private func fetchPrivacy() {
        guard !loadingPrivacy else { return }
        loadingPrivacy = true
        Task { @MainActor in
            defer { loadingPrivacy = false }
            var text = L.t("privacy_notice_load_failed")
            do {
                let resp = try await VerifyAPI.shared.privacyNotice()
                let t = resp.text ?? ""
                text = t.isEmpty ? L.t("privacy_notice_load_error") : t
            } catch {
                Log.warning("Aydınlatma metni yüklenemedi", error: error, category: .flow)
            }
            privacyDoc = PrivacyDoc(text: text)
        }
    }
}

// MARK: - MRZ tarama

private struct MRZScanStepView: View {
    var isDemo: Bool = false
    let onResult: (MRZParser.Result) -> Void
    @StateObject private var camera = CameraController(position: .back)
    @State private var scanner = MRZScanner()
    @State private var scanLineProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: .bottom)
            CameraPreview(session: camera.session).ignoresSafeArea(edges: .bottom)

            if camera.permissionDenied || camera.configurationFailed {
                cameraError
            } else {
                GeometryReader { geo in
                    let frameW = geo.size.width * 0.85
                    let frameH = frameW / 1.58  // credit card aspect ratio (Android 1.58:1)
                    let frameX = (geo.size.width - frameW) / 2
                    // Android vertical_bias=0.75 → frame center at ~55% of usable height
                    let usable = geo.size.height - 120  // reserve bottom for text
                    let frameY = usable * 0.5 - frameH / 2

                    ZStack(alignment: .topLeading) {
                        // Dark overlay outside scan frame
                        Color.black.opacity(0.55)
                            .mask(
                                Rectangle().fill(.white)
                                    .reverseMask(
                                        RoundedRectangle(cornerRadius: 8)
                                            .frame(width: frameW, height: frameH)
                                            .position(x: frameX + frameW / 2, y: frameY + frameH / 2)
                                    )
                            )

                        // Corner brackets
                        MRZCornerBrackets(frameX: frameX, frameY: frameY, w: frameW, h: frameH)

                        // Animated scan line
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color(red: 0.13, green: 0.39, blue: 0.94).opacity(0.8), .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: frameW - 8, height: 3)
                            .position(x: frameX + frameW / 2,
                                      y: frameY + 4 + (frameH - 8) * scanLineProgress)
                            .animation(.linear(duration: 1.6).repeatForever(autoreverses: true), value: scanLineProgress)
                    }
                    .ignoresSafeArea(edges: .bottom)

                    // Bottom instructions
                    VStack(spacing: 4) {
                        Text(L.t("scan_mrz_instruction"))
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        Text(L.t("scan_mrz_subtitle"))
                            .font(.system(size: 13)).foregroundColor(Color(white: 0.69))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height - 70)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scanLineProgress = 1
                    }
                }
            }
        }
        .onAppear {
            if isDemo {
                camera.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    camera.stop()
                    onResult(MRZParser.Result(documentNumber: "A12345678", dateOfBirth: "920101",
                                              dateOfExpiry: "301231", documentType: "ID"))
                }
            } else {
                scanner.onResult = { r in
                    camera.stop()
                    Log.info("MRZ okundu (register): type=\(r.documentType)", category: .nfc)
                    onResult(r)
                }
                camera.onFrame = { buf, o in scanner.process(buf, orientation: o) }
                camera.start()
            }
        }
        .onDisappear { camera.stop() }
    }

    private var cameraError: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 40)).foregroundStyle(.white)
            Text(L.t("camera_permission_required")).foregroundStyle(.white)
        }
    }
}

/// Dört köşede L-şekilli braket çizer (Android ScanFrameView eşdeğeri).
private struct MRZCornerBrackets: View {
    let frameX: CGFloat
    let frameY: CGFloat
    let w: CGFloat
    let h: CGFloat

    private let len: CGFloat = 24
    private let thick: CGFloat = 3
    private let color = Color.white.opacity(0.95)

    var body: some View {
        Canvas { ctx, _ in
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (frameX, frameY, 1, 1),
                (frameX + w, frameY, -1, 1),
                (frameX, frameY + h, 1, -1),
                (frameX + w, frameY + h, -1, -1)
            ]
            for (cx, cy, dx, dy) in corners {
                var hp = Path(); hp.move(to: CGPoint(x: cx, y: cy)); hp.addLine(to: CGPoint(x: cx + dx * len, y: cy))
                var vp = Path(); vp.move(to: CGPoint(x: cx, y: cy)); vp.addLine(to: CGPoint(x: cx, y: cy + dy * len))
                ctx.stroke(hp, with: .color(color), lineWidth: thick)
                ctx.stroke(vp, with: .color(color), lineWidth: thick)
            }
        }
    }
}

extension View {
    func reverseMask<M: View>(_ mask: M) -> some View {
        self.mask(
            ZStack {
                Rectangle().fill(.white)
                mask.blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

// MARK: - NFC

private struct NfcStepView: View {
    let status: String
    var isDemo: Bool = false
    var documentType: String = "ID"
    var retryMessage: String? = nil
    var onStart: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let retry = retryMessage {
                // Recoverable (kart kaydı/bağlantı koptu) — akış kırılmaz, tekrar dene.
                ZStack {
                    Circle().stroke(Theme.error.opacity(0.25), lineWidth: 2).frame(width: 160, height: 160)
                    Image(systemName: "wave.3.right").font(.system(size: 56)).foregroundColor(Theme.error)
                }
                Text(retry)
                    .font(.system(size: 16)).foregroundColor(Theme.onSurface)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                PrimaryGradientButton(title: L.t("handshake_retry"), action: onRetry)
                    .padding(.horizontal, 40)
            } else {
                ZStack {
                    Circle().stroke(Theme.nfcRing.opacity(0.3), lineWidth: 2).frame(width: 200, height: 200)
                    Circle().stroke(Theme.nfcRing.opacity(0.2), lineWidth: 2).frame(width: 150, height: 150)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 64))
                        .foregroundColor(Theme.themePrimary)
                }
                Text(documentType == "PASSPORT" ? L.t("nfc_passport_instruction") : L.t("nfc_id_card_instruction"))
                    .font(.system(size: 16))
                    .foregroundColor(Theme.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Text(isDemo ? L.t("nfc_searching") : status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Gerçek: NFC okumayı başlat. Demo: ~2s sonra biyometrik rızaya geç (onStart parent'ta sürer).
        .onAppear { onStart() }
    }
}

// MARK: - İşlem

struct ProcessingStepView: View {
    /// Kayıt akışında kart okuma ve yüz doğrulama BİTMİŞTİR; sunucu doğrulaması sürerken kullanıcı
    /// nerede olduğunu görmeli — bu adım saniyeler sürüyor ve tek spinner ne olduğunu anlatmıyordu
    /// (Android `layoutProcessingSteps` paritesi). QR doğrulamada bu iki adım yok → yalnız sunucu
    /// satırı gösterilir, tıpkı Android'in `qrMode` dalında olduğu gibi.
    var showFlowSteps: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.6).tint(Theme.themePrimary)
            Text(L.t("processing_title")).font(.system(size: 20, weight: .bold)).foregroundColor(Theme.onSurface)
            Text(L.t("processing_subtitle")).font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)

            VStack(alignment: .leading, spacing: 10) {
                if showFlowSteps {
                    ProcessingStepRow(titleKey: "step_card_read", done: true)
                    ProcessingStepRow(titleKey: "step_face_verified", done: true)
                }
                ProcessingStepRow(titleKey: "step_server_verifying", done: false)
            }
            .padding(.top, 8)

            Spacer()
            VStack(spacing: 6) {
                Text(L.t("secure_connection_title")).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.primary)
                Text(L.t("secure_connection_desc")).font(.system(size: 12)).foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// İşlem ekranındaki tek adım satırı: biten adım yeşil tik, süren adım dönen gösterge.
private struct ProcessingStepRow: View {
    let titleKey: String
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.success)
            } else {
                ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
            }
            Text(L.t(titleKey))
                .font(.system(size: 14, weight: done ? .regular : .semibold))
                .foregroundColor(done ? Theme.onSurfaceVariant : Theme.onSurface)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Başarı

struct SuccessStepView: View {
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Theme.success.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundColor(Theme.success)
            }
            Text(L.t("success_title"))
                .font(.system(size: 20, weight: .bold)).foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Text(L.t("success_desc"))
                .font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            PrimaryGradientButton(title: L.t("btn_go_home"), action: onHome)
                .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - Başarısızlık

struct FailedStepView: View {
    let title: String
    let message: String
    /// Kullanıcı bunu cihaz Ayarlar'ından düzeltebiliyorsa "Ayarları Aç" birincil buton olur.
    var offersSettings: Bool = false
    /// Cihazdaki kart verisi okunamıyorsa tek çıkış yolu onu silmektir → "Sil" birincil buton olur
    /// (Android `LoginKeystoreError` diyaloğu paritesi). Kullanıcı aksi halde döngüde kalıyordu.
    var onReset: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundColor(Theme.error)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Text(message).font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                if offersSettings {
                    // iOS'ta passcode ekranına DOĞRUDAN link yok — `App-Prefs:` private API'dir ve
                    // App Store reddi sebebidir. Public API yalnız uygulamanın kendi Ayarlar
                    // sayfasını açabiliyor; kullanıcı oradan geri gidip kilidi tanımlıyor. Yine de
                    // uygulamadan elle çıkmaktan iyi. (Android tarafı kurulum ekranını doğrudan açar.)
                    PrimaryGradientButton(title: L.t("btn_open_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                if let onReset {
                    PrimaryGradientButton(title: L.t("btn_delete"), action: onReset)
                }
                Button(action: onClose) {
                    Text(L.t("btn_close"))
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.themePrimary)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.themePrimary, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
