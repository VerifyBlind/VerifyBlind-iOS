import Foundation
import Sentry

/// Kart ekleme hunisi — kullanıcının akışı NEREDE bıraktığını görebilmek için "adıma ULAŞILDI"
/// olayları gönderir.
///
/// Terk olayını YAKALAMAYA ÇALIŞMAZ: kullanıcı uygulamayı zorla kapatır, telefon ölür, iOS süreci
/// askıya alır — o olay hiçbir zaman ulaşmaz. Terk sunucuda huniden çıkarılır: NFC'ye ulaşıp
/// liveness'a ulaşmayan akış NFC'de bırakılmıştır.
///
/// ⚠️ KİMLİKLE BAĞ YOK. `flowId` her akış başında üretilen rastgele bir gruplama anahtarıdır ve
/// yalnızca adımları birbirine bağlar; sunucu nonce'u sadece isteğin geçerliliğini doğrulamak için
/// kullanıp atar. Gönderim best-effort'tur — hata kullanıcıya YANSIMAZ ve akışı bloklamaz.
actor FlowTelemetry {

    enum Step: String {
        case handshake, mrz, nfc, liveness, submit, success
        /// Huni SIRASININ parçası değil — canlılık adımının neden kaybedildiğini işaretler.
        case livenessFailed = "liveness_failed"
        /// Huni SIRASININ parçası değil — çip okumasının neden kaybedildiğini işaretler.
        case nfcFailed = "nfc_failed"
        /// Tek bir hareketin sonucu. Hareket TÜRÜ adıma gömülü: `(flow_id, step)` benzersiz olduğu
        /// için her hareket akış başına bir kez sayılır ve "hangi hareket zor" doğrudan GROUP BY.
        case gestureLeft  = "gesture_left"
        case gestureRight = "gesture_right"
        case gestureSmile = "gesture_smile"
        case gestureBlink = "gesture_blink"
    }

    static let shared = FlowTelemetry()

    private var flowId = UUID()
    private var sentSteps: Set<Step> = []

    /// Yeni bir kart ekleme denemesi başladı — yeni gruplama anahtarı.
    ///
    /// Anahtarı çağırana da döndürür: geri bildirim e-postasına konunca kullanıcının ANLATISI ile
    /// hunideki satır birleşebiliyor. Bugüne kadar birleşmiyordu — "NFC'de zorlandım" diyen postayla,
    /// o akışın hangi adımda kaç saniye durduğunu gösteren satır arasında hiçbir bağ yoktu.
    ///
    /// ⚠️ Bağın bedeli bilinçli: tablo tasarım gereği kimlikle bağsız kalır, bağ YALNIZ gönüllü
    /// anlatan kullanıcı için ve YALNIZ destek posta kutusunda kurulur.
    @discardableResult
    func startFlow() -> String {
        flowId = UUID()
        sentSteps = []
        Self.setSentryTag(flowId.uuidString)
        return flowId.uuidString
    }

    /// Akış kapandı — Sentry etiketini temizler.
    ///
    /// Temizlemezsek akıştan SONRA üretilen olaylar (cüzdan, ayarlar, arka plan yenileme) bitmiş
    /// bir akışın kimliğini taşır ve incelemede yanlış satıra bakarız. `startFlow` etiketi zaten
    /// üzerine yazar; bu metot akış ile akış ARASINDAKİ boşluk için.
    func endFlow() {
        Self.setSentryTag(nil)
    }

    /// `flow_id`'yi GLOBAL Sentry scope'una etiket olarak yazar.
    ///
    /// Neden tek bir log mesajına değil de scope'a: destek postasındaki flow_id ile Sentry kaydını
    /// birleştirmek isterken tıkanan şey, olayın hangi akışa ait olduğunun HİÇBİR yerde yazmaması
    /// idi (eşleştirme zaman + cihaz + skor tahminiyle yapılıyordu). Scope etiketi bunu akış
    /// boyunca üretilen HER olaya taşır — yalnız canlılığa değil; NFC, kripto ve ağ hataları da
    /// aynı akışa bağlanır.
    private static func setSentryTag(_ value: String?) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.configureScope { scope in
            if let value { scope.setTag(value: value, key: "flow_id") }
            else { scope.removeTag(key: "flow_id") }
        }
    }

    /// Çip okuması başarısız bitti. `reason` sabit kümedendir (sunucu bilinmeyeni düşürür):
    /// tag_lost | auth_failed | aa_failed | doc_unsupported | read_error.
    ///
    /// Neden gerekti: hata sebebi bugüne kadar YALNIZ canlılık adımı için toplanıyordu. NFC
    /// muhtemelen en çok düşüş yaşanan adım ve "neden" sorusuna verecek tek satırımız yoktu —
    /// kart mı kaydı, MRZ anahtarı mı çipi açamadı, belge mi desteklenmiyor: üçü bambaşka düzeltme.
    ///
    /// SESSİZ TEKRARLARDA gönderilmez: `retryOrFail` üç kez sessizce yeniden deniyor, olay ancak
    /// kullanıcı gerçekten hata ekranını gördüğünde düşer.
    func nfcFailed(reason: String, nonce: String?) {
        guard let nonce, !nonce.isEmpty, !sentSteps.contains(.nfcFailed) else { return }
        sentSteps.insert(.nfcFailed)

        let body = Payload(
            nonce: nonce,
            flow_id: flowId.uuidString,
            step: Step.nfcFailed.rawValue,
            platform: "ios",
            app_version: Self.appVersion,
            detail: reason
        )
        Task.detached(priority: .background) {
            do {
                try await APIClient.shared.postNoContent("api/Verify/flow-event", body: body)
            } catch {
                Log.debug("Huni NFC hata olayı gönderilemedi: \(error.localizedDescription)", category: .flow)
            }
        }
    }

    /// TEK BİR HAREKETİN sonucu: hangi hareket, kaç ms sürdü, çözülene dek kaç yanlış yapıldı.
    ///
    /// Neden bu ayrıntı alınıyor da kare akışı alınmıyor: bu satırlar AKIŞLA büyür, kareyle değil.
    /// Jest kümesi dört elemanlı ve `(flow_id, step)` benzersiz → akış başına en fazla dört satır.
    /// Her karenin sinyalini göndermek ise kareyle büyürdü ve hiçbir kararı değiştirmezdi.
    ///
    /// Ne kararı değiştirir: bir hareket ötekilerin üç katı sürüyorsa ya jest kümesinden çıkar ya
    /// ekrandaki yönerge değişir. `wrongCount` ayrı bir şey söyler — süre "zor mu" derken o
    /// "komut anlaşılıyor mu" der.
    func gestureResolved(_ step: Step, durationMs: Int, wrongCount: Int, timedOut: Bool, nonce: String?) {
        guard let nonce, !nonce.isEmpty, !sentSteps.contains(step) else { return }
        sentSteps.insert(step)

        let body = Payload(
            nonce: nonce,
            flow_id: flowId.uuidString,
            step: step.rawValue,
            platform: "ios",
            app_version: Self.appVersion,
            detail: timedOut ? "timeout" : "ok",
            duration_ms: min(max(durationMs, 0), 120_000),
            wrong_count: min(max(wrongCount, 0), 10)
        )
        Task.detached(priority: .background) {
            do {
                try await APIClient.shared.postNoContent("api/Verify/flow-event", body: body)
            } catch {
                Log.debug("Huni hareket olayı gönderilemedi (\(step.rawValue)): \(error.localizedDescription)",
                          category: .flow)
            }
        }
    }

    /// Adıma ulaşıldı. Aynı adım bir akışta yalnız BİR kez gönderilir (sunucu da tekrarı yok sayar,
    /// ama gereksiz istek atmayalım): kullanıcı NFC'yi üç kez denerse huni üç kişi göstermemeli.
    func reached(_ step: Step, nonce: String?) {
        guard let nonce, !nonce.isEmpty, !sentSteps.contains(step) else { return }
        sentSteps.insert(step)

        let body = Payload(
            nonce: nonce,
            flow_id: flowId.uuidString,
            step: step.rawValue,
            platform: "ios",
            app_version: Self.appVersion
        )

        Task.detached(priority: .background) {
            do {
                try await APIClient.shared.postNoContent("api/Verify/flow-event", body: body)
            } catch {
                // Telemetri sessizdir: kullanıcı akışı bu isteğin sonucuna bağlı değil.
                Log.debug("Huni olayı gönderilemedi (\(step.rawValue)): \(error.localizedDescription)",
                          category: .flow)
            }
        }
    }

    /// Canlılık testi başarısız bitti. `reason` sabit kümedendir (sunucu bilinmeyeni düşürür).
    /// Aynı akışta ilk sebep kaydedilir — tekrar denemeler istatistiği şişirmesin.
    ///
    /// `score` cihaz-içi en iyi eşleşme yüzdesidir (0-100). Cihaz kapısı (MobileFaceNet, eşik %65)
    /// ile enclave kapısı (ArcFace, eşik 0.20) farklı model ve farklı ölçektir; cihazda düşen
    /// deneme enclave'e HİÇ ulaşmaz, dolayısıyla sunucudaki skor histogramı bu redleri göremez.
    /// Skoru buraya koymak "%64'te sınırdan dönen" ile "%10'da hiç tutmayan" ayrımını mümkün kılar.
    func livenessFailed(reason: String, nonce: String?, score: Int? = nil) {
        guard let nonce, !nonce.isEmpty, !sentSteps.contains(.livenessFailed) else { return }
        sentSteps.insert(.livenessFailed)

        let body = Payload(
            nonce: nonce,
            flow_id: flowId.uuidString,
            step: Step.livenessFailed.rawValue,
            platform: "ios",
            app_version: Self.appVersion,
            detail: reason,
            score: score.map { min(max($0, 0), 100) }
        )
        Task.detached(priority: .background) {
            do {
                try await APIClient.shared.postNoContent("api/Verify/flow-event", body: body)
            } catch {
                Log.debug("Huni hata olayı gönderilemedi: \(error.localizedDescription)", category: .flow)
            }
        }
    }

    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)+\(b)"
    }()

    private struct Payload: Encodable {
        let nonce: String
        let flow_id: String
        let step: String
        let platform: String
        let app_version: String
        var detail: String? = nil
        var score: Int? = nil
        var duration_ms: Int? = nil
        var wrong_count: Int? = nil
    }
}
