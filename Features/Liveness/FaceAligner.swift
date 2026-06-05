import UIKit
import CoreGraphics

/// Yüz hizalama (similarity transform) — Android `util/FaceEmbedder.getAlignedBitmap` portu.
///
/// Göz merkezlerini MobileFaceNet kanonik konumlarına (DST_LEFT/RIGHT_EYE) oturtacak şekilde
/// yüzü döndürür+ölçekler ve 112×112 üretir. **Enclave için ZORUNLU:** `BiometricService.cs`
/// `SmartFaceCrop` 112×112 selfie'yi yeniden hizalamadan kabul eder → hizalama istemcide olmalı.
///
/// Scalar mat (`params`) saftır → `Stage3SelfTest`'te doğrulanır; CGImage render'ı cihazda.
/// UIKit `UIGraphicsImageRenderer` Android `Canvas` ile aynı top-left/y-aşağı uzayı kullanır →
/// Android matris sırası (`T1·R·S·T2`) birebir korunur.
enum FaceAligner {

    static let inputSize = 112
    static let dstLeftEye = CGPoint(x: 38.29, y: 51.70)
    static let dstRightEye = CGPoint(x: 73.53, y: 51.50)
    static let minInterEyeDistance: CGFloat = 5

    struct AlignmentParams: Equatable {
        let scale: CGFloat
        let angleDegrees: CGFloat
        let usedFallback: Bool
    }

    /// Saf scalar hizalama parametreleri (render YOK). Android `getAlignedBitmap` matematiğinin
    /// scale/açı kısmı. Göz yoksa ya da gözler çok yakınsa fallback (düz ölçek) işaretlenir.
    static func params(leftEye: CGPoint?, rightEye: CGPoint?) -> AlignmentParams {
        guard let l = leftEye, let r = rightEye else {
            return AlignmentParams(scale: 1, angleDegrees: 0, usedFallback: true)
        }
        let dx = r.x - l.x
        let dy = r.y - l.y
        let srcDist = (dx * dx + dy * dy).squareRoot()
        if srcDist < minInterEyeDistance {
            return AlignmentParams(scale: 1, angleDegrees: 0, usedFallback: true)
        }
        let dstDx = dstRightEye.x - dstLeftEye.x
        let dstDy = dstRightEye.y - dstLeftEye.y
        let dstDist = (dstDx * dstDx + dstDy * dstDy).squareRoot()

        let scale = dstDist / srcDist
        let angleRad = atan2(dy, dx) - atan2(dstDy, dstDx)
        let angleDeg = angleRad * 180 / .pi
        return AlignmentParams(scale: scale, angleDegrees: angleDeg, usedFallback: false)
    }

    /// Hizalanmış 112×112 görüntü. Göz/uzaklık güvenilir değilse düz ölçek fallback.
    /// Hem skorlama hem enclave gönderimi için AYNI bitmap kullanılır (Android paritesi).
    static func alignedImage(from source: CGImage, leftEye: CGPoint?, rightEye: CGPoint?) -> CGImage? {
        let size = CGSize(width: inputSize, height: inputSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let sourceImage = UIImage(cgImage: source)

        let p = params(leftEye: leftEye, rightEye: rightEye)

        let result = renderer.image { ctx in
            let cg = ctx.cgContext
            if p.usedFallback || leftEye == nil {
                // Fallback: düz 112×112 ölçek (Android createScaledBitmap eşdeğeri)
                sourceImage.draw(in: CGRect(origin: .zero, size: size))
                return
            }
            // Android matris: dst = T1·R·S·T2 (CG row-vector concat sırasıyla birebir).
            // CGAffineTransform metotları pre-concat eder → bu çağrı sırası p = p·T1·R·S·T2 verir.
            let angleRad = p.angleDegrees * .pi / 180
            let transform = CGAffineTransform(translationX: dstLeftEye.x, y: dstLeftEye.y)
                .scaledBy(x: p.scale, y: p.scale)
                .rotated(by: -angleRad)
                .translatedBy(x: -leftEye!.x, y: -leftEye!.y)
            cg.concatenate(transform)
            sourceImage.draw(at: .zero)
        }
        return result.cgImage
    }
}
