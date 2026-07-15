import Foundation

/// Gülümseme tespiti — **göreceli** yaklaşım (blink ile aynı felsefe, ama smile SÜREKLİ durum).
///
/// Vision smilingProbability vermez; sinyal = ağız genişliği / göz arası mesafe
/// (`FaceAnalyzer.smileSpread`). Mutlak eşik kişiden kişiye değiştiği için, bu detektör kişinin
/// **nötr (düşük) seviyesini** (baseline) takip eder ve belirgin bir genişlemede (sürdürülen artış)
/// gülümseme sayar. Saf/durumlu → `Stage3SelfTest`'te dizi ile doğrulanır.
final class SmileDetector {
    private var baseline: Float = -1   // nötr ağız seviyesi; -1 = henüz yok
    private let riseFactor: Float      // baseline'ın bu katından genişse = gülümseme
    private let minSignal: Float

    // Cihaz geri bildirimi (2026-06-07): smile çok zor algılanıyordu → eşik gevşetildi (1.16→1.10).
    init(riseFactor: Float = 1.10, minSignal: Float = 0.35) {
        self.riseFactor = riseFactor
        self.minSignal = minSignal
    }

    /// `smileSpread` sinyalini besle; ağız nötr seviyenin belirgin üstüne çıkınca `true`.
    func feed(_ signal: Float) -> Bool {
        guard signal > 0 else { return false }
        if baseline < 0 { baseline = signal; return false } // ilk kare → baseline kur
        // Nötr (düşük) seviyeyi takip eden yavaş yükselen taban.
        baseline = min(signal, baseline * 1.02)
        guard baseline >= minSignal else { return false }
        return signal > baseline * riseFactor
    }

    /// Yeni challenge'a geçişte çağrılır — baseline sıfırlanır (yeni nötr ölçülür).
    func reset() {
        baseline = -1
    }
}
