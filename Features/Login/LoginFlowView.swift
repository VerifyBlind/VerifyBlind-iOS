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

    // QR kamerası varsayılan 2x açılır (CameraController defaultZoom). `zoom` butonun seçili durumu için.
    @StateObject private var camera = CameraController(position: .back, highestResolution: true, defaultZoom: 2.0)
    @State private var scanner = QRScanner()
    @State private var zoom: CGFloat = 2.0
    @State private var scanLineDown = false

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

                    // Mavi köşe çerçevesi + tarama çizgisi animasyonu (Android paritesi)
                    ZStack {
                        ScanCornersShape()
                            .stroke(Color(hex: "#2979FF"),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .square))
                            .frame(width: 240, height: 240)

                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.clear, Color(hex: "#2979FF"), .clear],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: 232, height: 3)
                            .offset(y: scanLineDown ? 116 : -116)
                    }
                    .frame(width: 240, height: 240)

                    Spacer()

                    // Marka görseli — alt orta, ekran genişliğinin 1/5'i (Android paritesi)
                    Image("scanBrand")
                        .resizable()
                        .scaledToFit()
                        .frame(width: UIScreen.main.bounds.width / 5)
                        .padding(.bottom, 64)
                }

                // Zoom butonu — sağ alt köşe (2x, varsayılan seçili). Tekrar basınca 1x.
                zoomPill("2x", active: abs(zoom - 2.0) < 0.01) {
                    let target: CGFloat = abs(zoom - 2.0) < 0.01 ? 1.0 : 2.0
                    zoom = target
                    camera.setZoom(target)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 16)
                .padding(.bottom, 40)
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
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                scanLineDown = true
            }
        }
        .onDisappear { camera.stop() }
    }

    /// Sağ alt köşe zoom pill butonu (2x).
    private func zoomPill(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 52, height: 40)
                .background(
                    active ? Theme.themePrimary : Color.black.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(active ? 0.9 : 0.3), lineWidth: active ? 1.5 : 1)
                )
        }
    }
}

/// QR tarama çerçevesi köşe braketleri — Android `view/ScanFrameView` eşdeğeri.
/// Tam dikdörtgen yerine 4 köşeyi (her biri L şeklinde) çizer.
private struct ScanCornersShape: Shape {
    var cornerLength: CGFloat = 28

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cl = cornerLength

        // Üst-sol
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + cl))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + cl, y: rect.minY))

        // Üst-sağ
        p.move(to: CGPoint(x: rect.maxX - cl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cl))

        // Alt-sağ
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cl))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - cl, y: rect.maxY))

        // Alt-sol
        p.move(to: CGPoint(x: rect.minX + cl, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cl))

        return p
    }
}
