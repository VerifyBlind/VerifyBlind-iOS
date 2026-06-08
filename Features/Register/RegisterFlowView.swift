import SwiftUI

/// Kayıt akışı ekranı — Android stepper + ViewFlipper (Hazırlık/MRZ/NFC/Liveness/İşlem/Başarı).
struct RegisterFlowView: View {
    let isDemo: Bool
    let onFinish: () -> Void

    @StateObject private var vm: RegisterViewModel

    init(isDemo: Bool, onFinish: @escaping () -> Void) {
        self.isDemo = isDemo
        self.onFinish = onFinish
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
                        isDemo: vm.isDemo),
                    onSuccess: { selfie, score in vm.onLiveness(selfie: selfie, score: score) },
                    onCancel: { vm.onLivenessCancel() }
                )
            case .processing:
                ProcessingStepView()
            case .success:
                SuccessStepView(onHome: onFinish)
            case .failed(let title, let message):
                FailedStepView(title: title, message: message, onClose: onFinish)
            default:
                VStack(spacing: 0) {
                    header
                    StepperHeader(steps: [L.t("step_prepare"), L.t("step_mrz"), L.t("step_nfc"), L.t("step_face")],
                                  current: currentStepIndex)
                    stepContent
                }
            }
        }
    }

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
            NfcStepView(status: vm.nfcStatus, isDemo: vm.isDemo, onStart: {
                if vm.isDemo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { vm.demoAdvanceToLiveness() }
                } else {
                    vm.startNfc()
                }
            })
        default:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onFinish) {
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

                PrimaryGradientButton(title: L.t("btn_start"), enabled: vm.kvkkAccepted) { vm.begin() }
                    .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

// MARK: - MRZ tarama

private struct MRZScanStepView: View {
    var isDemo: Bool = false
    let onResult: (MRZParser.Result) -> Void
    @StateObject private var camera = CameraController(position: .back)
    @State private var scanner = MRZScanner()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: .bottom)
            CameraPreview(session: camera.session).ignoresSafeArea(edges: .bottom)

            if camera.permissionDenied || camera.configurationFailed {
                cameraError
            } else {
                VStack {
                    Text(L.t("scan_mrz_instruction"))
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .padding(10).background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 16)
                    Text(L.t("scan_mrz_subtitle"))
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.top, 4)
                    Spacer()
                    RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.85), lineWidth: 2)
                        .frame(height: 120).padding(.horizontal, 24)
                    Spacer()
                }
            }
        }
        .onAppear {
            if isDemo {
                // Android demo: kamera ~2s açık kalır, sonra sahte MRZ enjekte edilir.
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

// MARK: - NFC

private struct NfcStepView: View {
    let status: String
    var isDemo: Bool = false
    var onStart: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.nfcRing.opacity(0.3), lineWidth: 2).frame(width: 200, height: 200)
                Circle().stroke(Theme.nfcRing.opacity(0.2), lineWidth: 2).frame(width: 150, height: 150)
                Image(systemName: "wave.3.right")
                    .font(.system(size: 64))
                    .foregroundColor(Theme.themePrimary)
            }
            Text(L.t("nfc_id_card_instruction"))
                .font(.system(size: 16))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text(isDemo ? L.t("nfc_searching") : status)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Gerçek: NFC okumayı başlat. Demo: ~2s sonra liveness'a geç (onStart parent'ta sürer).
        .onAppear { onStart() }
    }
}

// MARK: - İşlem

struct ProcessingStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.6).tint(Theme.themePrimary)
            Text(L.t("processing_title")).font(.system(size: 20, weight: .bold)).foregroundColor(Theme.onSurface)
            Text(L.t("processing_subtitle")).font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
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
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundColor(Theme.error)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Text(message).font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            Button(action: onClose) {
                Text(L.t("btn_close"))
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.themePrimary)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.themePrimary, lineWidth: 1.5))
            }
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
