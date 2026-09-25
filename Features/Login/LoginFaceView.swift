import SwiftUI

/// Girişteki canlı yüz ekranı — Android `LoginFaceActivity` + `activity_login_face.xml` paritesi.
///
/// `LivenessView`'ün sadeleştirilmiş hâli: en iyi kare, ardından TEK hareket (2026-09-26). Adım
/// sayacı ve kılavuz yok; komut ve nasıl yapılacağı durum satırının yerinde gösterilir. Ekran ne
/// kadar sade olursa 2FA/step-up kullanımı o kadar mümkün kalır.
struct LoginFaceView: View {
    @StateObject private var viewModel = LoginFaceViewModel()
    @ObservedObject private var camera: CameraController

    /// (hizalanmış 112×112 selfie PNG, AYNI karenin 2,7× anti-spoof JPEG'i, cihaz ölçüleri,
    /// hareket kanıtı)
    let onSuccess: (Data, Data, DeviceFrameMetrics?, ChoreographyProof?) -> Void
    /// Kare/hareket alınamadı veya kullanıcı vazgeçti → çağıran giriş isteğini GÖNDERMEZ
    /// (fail-closed). `true`: istenen hareket algılanamadı.
    let onCancel: (_ moveFailed: Bool) -> Void

    @State private var savedBrightness: CGFloat?

    private let grayColor = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555
    private let redColor  = Color(red: 1.0, green: 0.267, blue: 0.267)   // #FF4444

    /// - Parameter loginNonce: QR isteğinin nonce'u — tek hareket ondan türetilir (`LoginEvent`);
    ///   enclave aynı nonce'tan aynısını türetip ölçer.
    init(faceRefB64: String?,
         loginNonce: String?,
         onSuccess: @escaping (Data, Data, DeviceFrameMetrics?, ChoreographyProof?) -> Void,
         onCancel: @escaping (_ moveFailed: Bool) -> Void) {
        let vm = LoginFaceViewModel()
        vm.faceRefB64 = faceRefB64
        vm.loginEvent = loginNonce.flatMap { LoginEvent.forNonce($0) }
        _viewModel = StateObject(wrappedValue: vm)
        _camera = ObservedObject(wrappedValue: vm.camera)
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if camera.permissionDenied || camera.configurationFailed {
                permissionOverlay
            } else {
                content
                backButton
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.onSuccess = { png, crop, metrics, proof in onSuccess(png, crop, metrics, proof) }
            viewModel.onFailure = { moveFailed in onCancel(moveFailed) }
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            if let b = savedBrightness { UIScreen.main.brightness = b }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text(L.t("login_face_title"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 24)

            Text(L.t("login_face_subtitle"))
                .font(.system(size: 14))
                .foregroundColor(grayColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            frameCamera
                .padding(.top, 16)

            // Canlı benzerlik yüzdesi — kayıt ekranındaki göstergenin karşılığı. Burada
            // HİÇBİR ŞEYİ ENGELLEMEZ, yalnız "ilerliyorum" geri bildirimi verir.
            if let percent = viewModel.matchPercent {
                Text("\(percent)%")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(viewModel.matchIsGood
                        ? Color(red: 0.16, green: 0.65, blue: 0.27)
                        : redColor)
                    .padding(.top, 8)
            }

            if let instruction = viewModel.moveInstruction {
                // Tek hareket: komut büyük ve koyu, nasıl yapılacağı altında.
                VStack(spacing: 6) {
                    Text(instruction)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.black)
                    if !viewModel.moveHint.isEmpty {
                        Text(viewModel.moveHint)
                            .font(.system(size: 15))
                            .foregroundColor(grayColor)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            } else {
                Text(L.t(viewModel.statusKey))
                    .font(.system(size: 15))
                    .foregroundColor(grayColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
            }
        }
    }

    /// Kamera penceresi — `LivenessView.frameCamera` ile aynı görsel dil (`FaceFrameView`: beyaz
    /// zemin üzerinde yuvarlatılmış kesit, köşe işaretleri; oval DEĞİL). Kullanıcı iki ekranı da aynı
    /// şey olarak tanısın diye.
    private var frameCamera: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.8, geo.size.height / FaceFrameView<EmptyView>.aspect)
            ZStack {
                FaceFrameView(width: side, aligned: viewModel.frameAligned, progress: viewModel.timeProgress) {
                    CameraPreview(session: camera.session)
                }

                if let warning = viewModel.warning {
                    VStack {
                        Text(warning)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(redColor.opacity(0.8))
                        Spacer()
                    }
                    .frame(width: side, height: side * FaceFrameView<EmptyView>.aspect)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var backButton: some View {
        VStack {
            HStack {
                Button(action: {
                    viewModel.cancel()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(12)
                }
                Spacer()
            }
            Spacer()
        }
    }

    private var permissionOverlay: some View {
        VStack(spacing: 16) {
            Text(L.t("camera_permission_required"))
                .font(.system(size: 16))
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(L.t("btn_cancel")) { viewModel.cancel() }
        }
    }
}
