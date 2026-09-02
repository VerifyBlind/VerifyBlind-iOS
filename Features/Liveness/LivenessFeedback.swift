import AVFoundation
import UIKit

/// Liveness jest geri bildirimi — ses + haptic.
///
/// "Başını SAĞA çevir" komutunu yerine getiren kullanıcı EKRANI GÖREMİYOR. Onay yalnızca görsel
/// (✅) olduğu sürece hareketinin kabul edildiğini fark edemiyor, bekliyor ve süreyi harcıyor
/// (kullanıcı geri bildirimi 2026-08-21). Ses cihazın zil anahtarına bağlı olduğundan haptic
/// HER ZAMAN yanında verilir — sessiz moddaki kullanıcı da geri bildirimsiz kalmaz.
///
/// Ses dosyaları Android `res/raw/liveness_*.wav` ile **birebir aynıdır** (aynı üretici, aynı
/// dalga formu) → iki platformda aynı işitsel dil.
final class LivenessFeedback {

    enum Event {
        case stepOk   // hareket kabul edildi
        case wrong    // yanlış hareket
        case done     // tüm dizi tamamlandı
        case nudge    // hareket süresi azalıyor — SESSİZ, yalnız hafif haptic
    }

    private var players: [Event: AVAudioPlayer] = [:]
    private let notifier = UINotificationFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init() {
        for (event, name) in [(Event.stepOk, "liveness_ok"),
                              (Event.wrong, "liveness_wrong"),
                              (Event.done, "liveness_done")] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                Log.warning("Liveness ses dosyası yüklenemedi: \(name).wav", category: .liveness)
                continue
            }
            player.prepareToPlay()
            player.volume = 1.0
            players[event] = player
        }
        notifier.prepare()
        impact.prepare()
    }

    /// Liveness başlarken çağrılır.
    ///
    /// `.ambient` kullanılıyordu ve o kategori zil anahtarına uyar: telefon sessizdeyken jest sesi
    /// HİÇ çıkmıyordu, yalnız titreşim kalıyordu (kullanıcı geri bildirimi 2026-08-21). Android'de
    /// SoundPool `USAGE_ASSISTANCE_SONIFICATION` ile medya akışından çalıyor ve sessiz modda da
    /// duyuluyor — parite için iOS de duyulmalı. Bu ses bir "medya" değil, kullanıcının hareketini
    /// onaylayan İŞLEVSEL bir sinyaldir: kafası çevrikken ekranı göremediği için geri bildirimin
    /// tek görünür kanalı odur. `.mixWithOthers` müziği kesmez, `.duckOthers` kısa süre kısar.
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            Log.warning("Liveness ses oturumu açılamadı: \(error.localizedDescription)", category: .liveness)
        }
    }

    /// Liveness biterken çağrılır — oturumu tutmaya devam etmeyiz.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Ana kuyrukta çalar (haptic ve AVAudioPlayer ana kuyruk ister); video kuyruğundan da çağrılabilir.
    func play(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Dürtme sessizdir: 4. bir ton kullanıcıyı şaşırtır, hafif bir dokunuş "acele et" demeye
            // yeter ve kafa çevrikken de hissedilir.
            if event == .nudge {
                self.impact.impactOccurred()
                self.impact.prepare()
                return
            }
            if let player = self.players[event] {
                player.currentTime = 0   // hızlı arka arkaya jestlerde yeniden tetiklenebilsin
                player.play()
            }
            self.notifier.notificationOccurred(event == .wrong ? .error : .success)
            self.notifier.prepare()
        }
    }
}
