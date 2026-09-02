import CoreGraphics

/// Yüz tespitinden türetilen nötr sinyaller — tespit kütüphanesini (FaceAnalyzer) saf karar
/// mantığından (LivenessGestureDetector) ayırır → deterministik self-test edilebilirlik.
///
/// Bu değerler artık Android'le AYNI kaynaktan, ML Kit `Face`'ten doğrudan okunuyor
/// (`headEulerAngleY`, `leftEyeOpenProbability`, `smilingProbability`...). Vision döneminde
/// bir kısmı landmark geometrisinden türetiliyordu; iOS'a özgü liveness hatalarının kaynağı oydu.
struct FaceSignals {
    /// Kafa açıları (derece). MLKit `headEulerAngle{Y,X,Z}` eşdeğeri.
    /// `yaw`: sağ/sol, `pitch`: yukarı/aşağı, `roll`: eğim.
    var yaw: Float
    var pitch: Float
    var roll: Float

    /// Göz açıklık olasılığı [0,1] — ML Kit `leftEyeOpenProbability` / `rightEyeOpenProbability`.
    var leftEyeOpen: Float
    var rightEyeOpen: Float

    /// Gülümseme OLASILIĞI [0,1] — ML Kit `smilingProbability`.
    ///
    /// ⚠️ Eskiden bu alan ham bir ORANDI (ağız genişliği / göz arası mesafe, nötr ~1.0). Eşik de
    /// ona göre 1.45'ti. Artık [0,1] olasılık ve eşik Android'le aynı: 0.8. Bu alanı okuyan
    /// herhangi bir yeni kod bu ölçek farkını varsaymamalı.
    var smile: Float

    /// Görüntü piksel uzayında yüz sınırlayıcı kutusu (kalite skoru için).
    var boundingBox: CGRect

    /// Görüntü piksel uzayında göz merkezleri (alignment için). Yoksa nil → fallback hizalama.
    var leftEye: CGPoint?
    var rightEye: CGPoint?

    /// Sınıflandırma olasılıkları bu karede GERÇEKTEN geldi mi?
    ///
    /// ML Kit, yüzü bulsa bile küçük/kenarda/bulanık karelerde gülümseme ve göz-açıklık
    /// olasılıklarını vermeyebilir. O durumda alanlar varsayılanla dolar — bunlar ölçüm değil,
    /// "bilinmiyor" demektir. Jest mantığı bunları ölçüm sanıp yorumluyordu: yüz kadrajdan çıkıp
    /// geri girdiğinde ilk kareler kırpılmadığı halde blink sayılıyordu (kullanıcı geri bildirimi
    /// 2026-08-21). Bu bayrak false ise kare jest kararında KULLANILMAZ (kalite skoruna girer).
    var landmarksOK: Bool = true
}
