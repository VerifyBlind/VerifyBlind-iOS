import SwiftUI

/// Girişteki canlı yüz ekranı — Android `LoginFaceActivity` + `activity_login_face.xml` paritesi.
///
/// `LivenessView`'ün sadeleştirilmiş hâli: adım sayacı, komut metni, geri sayım halkası ve alt
/// ipucu YOK. Girişte jest yoktur ve ekran ~2 saniyede kapanmalıdır — ekran ne kadar sade olursa
/// 2FA/step-up kullanımı o kadar mümkün kalır.
struct LoginFaceView: View {
    @StateObject private var viewModel = LoginFaceViewModel()
    @ObservedObject private var camera: CameraController

    /// (hizalanmış 112×112 selfie PNG, AYNI karenin 2,7× anti-spoof JPEG'i, cihaz ölçüleri)
    let onSuccess: (Data, Data, DeviceFrameMetrics?) -> Void
    /// Kare alınamadı veya kullanıcı vazgeçti → çağıran giriş isteğini GÖNDERMEZ (fail-closed).
    let onCancel: () -> Void

    @State private var savedBrightness: CGFloat?

    private let grayColor = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555
    private let redColor  = Color(red: 1.0, green: 0.267, blue: 0.267)   // #FF4444

    init(faceRefB64: String?,
         onSuccess: @escaping (Data, Data, DeviceFrameMetrics?) -> Void,
         onCancel: @escaping () -> Void) {
        let vm = LoginFaceViewModel()
        vm.faceRefB64 = faceRefB64
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
            viewModel.onSuccess = { png, crop, metrics in onSuccess(png, crop, metrics) }
            viewModel.onFailure = { onCancel() }
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

            ovalCamera
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

            Text(L.t(viewModel.statusKey))
                .font(.system(size: 15))
                .foregroundColor(grayColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
        }
    }

    /// Oval kamera penceresi — `LivenessView.ovalCamera` ile aynı görsel dil (beyaz zemin üzerinde
    /// oval kesit, kırmızı kenarlık). Kullanıcı iki ekranı da aynı şey olarak tanısın diye.
    private var ovalCamera: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.8, geo.size.height)
            ZStack {
                CameraPreview(session: camera.session)
                    .frame(width: side, height: side * 1.25)
                    .clipShape(Ellipse())
                    .overlay(Ellipse().stroke(redColor, lineWidth: 3))

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
                    .frame(width: side, height: side * 1.25)
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
