import SwiftUI

/// Login (QR ile Doğrula) akış ekranı — QR tara → consent → işlem → başarı.
struct LoginFlowView: View {
    let onFinish: () -> Void
    @StateObject private var vm: LoginViewModel

    /// `initialPayload` = deep-link URL (varsa QR tarama atlanır, doğrudan o nonce ile başlar).
    init(onFinish: @escaping () -> Void, initialPayload: String? = nil) {
        self.onFinish = onFinish
        _vm = StateObject(wrappedValue: LoginViewModel(initialPayload: initialPayload))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch vm.step {
            case .scanning:
                QRScanStepView(onResult: { vm.onQr($0) }, onCancel: onFinish)
            case .loadingPartner, .processing:
                ProcessingStepView()
            case .consent:
                consentOverlay
            case .success:
                loginSuccess
            case .rejected:
                Color.clear.onAppear { onFinish() }
            case .failed(let title, let message):
                FailedStepView(title: title, message: message, onClose: onFinish)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.step)
    }

    private var consentOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5).ignoresSafeArea()
            if let info = vm.partnerInfo {
                ConsentBottomSheet(info: info, onApprove: { vm.approve() }, onReject: { vm.reject() })
                    .transition(.move(edge: .bottom))
            }
        }
    }

    private var loginSuccess: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Theme.success.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundColor(Theme.success)
            }
            Text(L.t("login_success_status"))
                .font(.system(size: 22, weight: .bold)).foregroundColor(Theme.onSurface)
            Text(L.t("identity_verified"))
                .font(.system(size: 14)).foregroundColor(Theme.onSurfaceVariant)
            Spacer()
            PrimaryGradientButton(title: L.t("btn_go_home"), action: onFinish)
                .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// QR tarama adımı — Android QR ViewFlipper. Kamera (arka) + QRScanner.
private struct QRScanStepView: View {
    let onResult: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = CameraController(position: .back)
    @State private var scanner = QRScanner()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            if camera.permissionDenied || camera.configurationFailed {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill").font(.system(size: 40)).foregroundStyle(.white)
                    Text(L.t("camera_permission_required")).foregroundStyle(.white)
                }
            } else {
                VStack {
                    HStack {
                        Button(action: onCancel) {
                            Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white).padding(12)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        Spacer()
                    }
                    .padding(16)

                    Text(L.t("scan_qr_instruction"))
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .padding(10).background(.black.opacity(0.5), in: Capsule())

                    Spacer()
                    RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 240, height: 240)
                    Spacer()
                }
            }
        }
        .onAppear {
            scanner.onResult = { payload in
                camera.stop()
                Log.info("QR okundu (login)", category: .flow)
                onResult(payload)
            }
            camera.onFrame = { buf, o in scanner.process(buf, orientation: o) }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}
