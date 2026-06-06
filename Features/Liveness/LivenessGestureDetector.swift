import CoreGraphics

/// Jest tespiti + kare kalite skoru — Android `LivenessActivity.detectGesture` /
/// `calculateQualityScore` **saf** portu. `FaceSignals` üzerinde çalışır → self-test edilebilir.
///
/// ⚠️ Yaw işareti: Android MLKit'te `headEulerAngleY > 0` = FaceLeft (kullanıcı geri bildirimiyle
/// "SWAPPED"). Vision `VNFaceObservation.yaw` işaret/ölçek farkı olabilir → `FaceAnalyzer` yaw'ı
/// MLKit dereceleriyle hizalar (gerekirse cihazda kalibre edilir). Eşikler Android ile aynı.
enum LivenessGestureDetector {

    static let yawThreshold: Float = 20
    /// Smile artık ham oran (ağız genişliği / göz arası); bu yüksek bar STATİK fallback'tir.
    /// Asıl tespit göreceli `SmileDetector` ile (kişinin nötr seviyesine göre).
    static let smileThreshold: Float = 1.45
    static let blinkThreshold: Float = 0.1

    /// Tespit edilen jest (yoksa nil). Android `detectGesture` ile birebir.
    static func detect(_ s: FaceSignals) -> LivenessAction? {
        if s.yaw > yawThreshold { return .faceLeft }
        if s.yaw < -yawThreshold { return .faceRight }
        if s.smile > smileThreshold { return .smile }
        if s.leftEyeOpen < blinkThreshold && s.rightEyeOpen < blinkThreshold { return .blink }
        return nil
    }

    /// Kare kalitesi [0,100] — kafa açısı, göz açıklığı, ortalama ve boyut cezalarıyla.
    /// Android `calculateQualityScore` ile birebir. `imageSize` = analiz görüntüsünün piksel boyutu.
    static func qualityScore(_ s: FaceSignals, imageSize: CGSize) -> Float {
        var score: Float = 100

        // 1. Kafa açıları (bakış sapması cezası)
        let x = abs(s.pitch) // yukarı/aşağı (MLKit headEulerAngleX)
        let y = abs(s.yaw)   // sağ/sol (headEulerAngleY)
        let z = abs(s.roll)  // eğim (headEulerAngleZ)
        if x > 10 { score -= (x - 10) * 2 }
        if y > 10 { score -= (y - 10) * 2 }
        if z > 10 { score -= (z - 10) * 2 }

        // 2. Gözler açık (göz kırpma cezası)
        if s.leftEyeOpen < 0.8 { score -= (0.8 - s.leftEyeOpen) * 50 }
        if s.rightEyeOpen < 0.8 { score -= (0.8 - s.rightEyeOpen) * 50 }

        // 3. Ortalama (kenarda olma cezası)
        let imgW = Float(imageSize.width)
        let imgH = Float(imageSize.height)
        if imgW > 0, imgH > 0 {
            let centerX = Float(s.boundingBox.midX)
            let centerY = Float(s.boundingBox.midY)
            let distX = abs(centerX - imgW / 2)
            let distY = abs(centerY - imgH / 2)
            score -= (distX / imgW) * 20
            score -= (distY / imgH) * 20

            // 4. Boyut (çok küçük/uzak cezası)
            if Float(s.boundingBox.width) < imgW * 0.25 { score -= 30 }
        }

        return min(max(score, 0), 100)
    }
}
