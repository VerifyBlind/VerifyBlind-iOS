import CoreGraphics

/// Yüz tespitinden türetilen nötr sinyaller — Vision'ı (FaceAnalyzer) saf karar mantığından
/// (LivenessGestureDetector) ayırır → deterministik self-test edilebilirlik.
///
/// Android `LivenessActivity`'de bu değerler doğrudan ML Kit `Face`'ten okunuyordu
/// (`headEulerAngleY`, `leftEyeOpenProbability`, `smilingProbability`...). Vision bunların
/// bir kısmını hazır vermez → `FaceAnalyzer` göz/ağız landmark geometrisinden türetir.
struct FaceSignals {
    /// Kafa açıları (derece). MLKit `headEulerAngle{Y,X,Z}` eşdeğeri.
    /// `yaw`: sağ/sol, `pitch`: yukarı/aşağı, `roll`: eğim.
    var yaw: Float
    var pitch: Float
    var roll: Float

    /// Göz açıklık olasılığı [0,1]. Vision'da landmark açıklık oranından türetilir
    /// (MLKit `leftEyeOpenProbability` / `rightEyeOpenProbability` eşdeğeri).
    var leftEyeOpen: Float
    var rightEyeOpen: Float

    /// Gülümseme olasılığı [0,1] — ağız landmark geometrisinden türetilir
    /// (MLKit `smilingProbability` eşdeğeri).
    var smile: Float

    /// Görüntü piksel uzayında yüz sınırlayıcı kutusu (kalite skoru için).
    var boundingBox: CGRect

    /// Görüntü piksel uzayında göz merkezleri (alignment için). Yoksa nil → fallback hizalama.
    var leftEye: CGPoint?
    var rightEye: CGPoint?
}
