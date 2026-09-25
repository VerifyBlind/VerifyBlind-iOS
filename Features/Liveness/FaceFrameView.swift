import SwiftUI

/// Kamera önizlemesinin yüz çerçevesi — köşeleri yuvarlatılmış dikdörtgen pencere, köşelerinde
/// durum renginde işaretler, isteğe bağlı olarak çerçeve boyunca eriyen süre çizgisi. Android
/// `FaceFrameOverlayView` karşılığı; kayıt ve giriş ekranı aynı görünümü kullanır.
///
/// ## Neden oval DEĞİL (2026-09-25)
///
/// Eskiden pencere ovaldi. Özçekim arayüzünde yüzü oval bir çerçeveyle çevreleyen tasarımın ABD
/// tasarım patenti var (FaceTec). Kullanıcı kararı: bilinen bir patentin üstünde durulmaz. Aynı
/// sebeple TEK boyut var — farklı büyüklükte çerçeveler gösterip kullanıcıyı yaklaştırıp
/// uzaklaştırmak da patentli bir akış.
struct FaceFrameView<Content: View>: View {
    /// Pencerenin genişliği; yükseklik 4:5 portre oranından türetilir.
    let width: CGFloat
    /// Yüz yerinde ve hazır → yeşil; değilse kırmızı.
    var aligned: Bool
    /// Kalan süre (0...1). nil → süre çizgisi yok, çerçeve durum renginde.
    var progress: Double?
    @ViewBuilder var content: () -> Content

    static var aspect: CGFloat { 1.25 }

    private let waitingColor = Color(red: 1.0, green: 0.267, blue: 0.267)   // #FF4444
    private let alignedColor = Color(red: 0.298, green: 0.686, blue: 0.314) // #4CAF50
    private let trackColor = Color(white: 0.88)
    private let lowTimeColor = Color(red: 0.95, green: 0.61, blue: 0.07)    // #F29B12

    var body: some View {
        let height = width * Self.aspect
        let radius = width * 0.10
        let window = RoundedRectangle(cornerRadius: radius, style: .circular)
        let stateColor = aligned ? alignedColor : waitingColor

        ZStack {
            content()
                .frame(width: width, height: height)
                .clipShape(window)

            if let progress {
                window
                    .stroke(trackColor, lineWidth: 2)
                    .frame(width: width, height: height)
                window
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(progress <= LivenessViewModel.lowTimeFraction ? lowTimeColor : stateColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: width, height: height)
                    .animation(.linear(duration: 0.1), value: progress)
            } else {
                window
                    .stroke(stateColor, lineWidth: 2)
                    .frame(width: width, height: height)
            }

            CornerBrackets(cornerRadius: radius, arm: width * 0.16)
                .stroke(stateColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: width, height: height)
        }
    }
}

/// Pencerenin dört köşesinde, köşe yayının üstünden iki kola uzanan L işaretleri.
struct CornerBrackets: Shape {
    var cornerRadius: CGFloat
    var arm: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = cornerRadius

        // Sol üst
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r + arm, y: rect.minY))

        // Sağ üst
        p.move(to: CGPoint(x: rect.maxX - r - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + arm))

        // Sağ alt
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r - arm, y: rect.maxY))

        // Sol alt
        p.move(to: CGPoint(x: rect.minX + r + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - arm))

        return p
    }
}
