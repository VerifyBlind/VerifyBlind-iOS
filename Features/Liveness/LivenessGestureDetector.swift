import CoreGraphics

/// Gülümseme eşikleri + kare kalite skoru — Android `calculateQualityScore` **saf** portu.
/// `FaceSignals` üzerinde çalışır → self-test edilebilir.
///
/// Hareket KARARI artık `EventSequencer`'da (olay dizisi). Kafa çevirme dizide yok (2026-09-25);
/// eski `detect` ve yaw/blink eşikleri onunla birlikte kalktı.
enum LivenessGestureDetector {
    /// Gülümseme OLASILIĞI eşiği (Android `SMILE_THRESHOLD`).
    ///
    /// Eskiden 1.45'ti çünkü sinyal bir olasılık değil, ham bir orandı (ağız genişliği / göz arası)
    /// ve mutlak eşik kişiden kişiye tutmadığı için asıl kararı, kişinin nötr seviyesini izleyen
    /// göreceli bir dedektör veriyordu. O baseline kısa bir bozulmada nötr yüzü "gülümsüyor"
    /// sayacak kadar kırılgandı ve ML Kit'e geçince kaldırıldı: eğitilmiş bir olasılık geldiği
    /// için mutlak eşik yeniden anlamlı.
    static let smileThreshold: Float = 0.8
    /// Bu değerin ALTI "nötr yüz" sayılır (Android `SMILE_RELAX_BELOW`) — gülümseme ancak
    /// nötrden bir GEÇİŞ olarak kabul edilir, bkz. `isSmileNeutral`.
    static let smileRelaxBelow: Float = 0.4

    /// Nötr sayılacak kadar düşük mü? (negatif = henüz kare yok → nötr DEĞİL sayılır.)
    /// Android `isSmileNeutral` ile birebir.
    static func isSmileNeutral(_ probability: Float) -> Bool {
        probability >= 0 && probability < smileRelaxBelow
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
