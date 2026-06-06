import Foundation

/// Göz kırpma tespiti — **göreceli** yaklaşım.
///
/// Vision, MLKit'in `eyeOpenProbability`'si gibi hazır bir göz-açıklık olasılığı vermez; biz onu
/// göz landmark açıklık oranından türetiyoruz (`FaceAnalyzer.eyeOpenProbability`). Cihaz testinde
/// (2026-06-06) Vision'ın gözü blink'te TAM kapatmadığı görüldü → mutlak eşik (0.1,
/// `LivenessGestureDetector`) hiç tetiklenmiyordu. Bu detektör kişinin **kendi açık-göz seviyesini**
/// (baseline) takip eder ve belirgin bir düşüş + geri açılma (kapan→açıl döngüsü) görünce blink sayar.
/// Saf/durumlu → `Stage3SelfTest`'te bir dizi ile deterministik doğrulanır.
final class BlinkDetector {
    private var baseline: Float = 0
    private var armed = false

    private let closeFrac: Float    // baseline'ın bu oranının ALTI = kapalı
    private let reopenFrac: Float   // baseline'ın bu oranının ÜSTÜ = yeniden açık
    private let minBaseline: Float  // baseline bunun altındaysa henüz güvenilir açık göz yok

    init(closeFrac: Float = 0.65, reopenFrac: Float = 0.85, minBaseline: Float = 0.3) {
        self.closeFrac = closeFrac
        self.reopenFrac = reopenFrac
        self.minBaseline = minBaseline
    }

    /// `min(leftEyeOpen, rightEyeOpen)` besle. Tam bir kapan→açıl döngüsü tamamlanınca `true`.
    func feed(_ eyeOpen: Float) -> Bool {
        // Açık-göz seviyesini takip eden yavaş düşen tavan.
        baseline = max(eyeOpen, baseline * 0.97)
        guard baseline >= minBaseline else { return false }

        if eyeOpen < baseline * closeFrac {
            armed = true
        } else if armed && eyeOpen > baseline * reopenFrac {
            armed = false
            return true
        }
        return false
    }

    /// Yeni challenge'a geçişte çağrılır — yarım kalan "kapandı" durumunu sıfırlar (baseline korunur).
    func resetArmed() {
        armed = false
    }
}
