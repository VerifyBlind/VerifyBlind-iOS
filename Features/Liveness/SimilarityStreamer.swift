import Foundation
import UIKit

/// Canlılık sırasında enclave'e kare gönderip benzerlik kararını alan istemci —
/// Android `SimilarityStreamer` portu (parite ŞART).
///
/// **Neden var:** bugün cihazdaki 0.65 kapısında düşen deneme enclave'e HİÇ ulaşmıyor, dolayısıyla
/// kaç meşru kullanıcıyı hatalı reddettiğimiz bilinmiyor. Bu sınıf iki şeyi birden çözer:
/// (a) cihaz skoru 0.65'in altında kalsa bile enclave "benzerlik geçti" derse submit açılır,
/// (b) her deneme ölçülebilir bir veri noktasına dönüşür.
///
/// **Ekrandaki 0.65 DEĞİŞMEZ.** Kullanıcı anlık skorunu görüp ortamı düzeltmeli, gözlüğünü
/// çıkarmalı; bu geri bildirim baskısı ürünün kalitesini koruyor ve zayıflatılmıyor. Enclave
/// onayı yalnızca İKİNCİ bir submit yolu açar.
///
/// **Bu bir güvenlik gevşemesi değildir:** cihazdaki 0.65 hiçbir zaman güvenlik kontrolü değildi
/// (`isIdentityVerified` yerel bir boolean; kötü niyetli istemci onu zaten yamalayabilir). Gerçek
/// karar hep enclave'de ve register akışından hiçbir kontrol kaldırılmadı.
///
/// **Her şey best-effort:** ağ hatası, hazırlık başarısızlığı, oran sınırı — hiçbiri akışı bozmaz.
/// Streaming çalışmazsa kullanıcı bugünkü davranışla (yalnız cihaz kapısı) devam eder ve hiçbir
/// şey kaybetmez; kaybeden biz oluruz (ölçüm).
///
/// İPLİK DİSİPLİNİ: `LivenessViewModel` gibi bu sınıf da video kuyruğundan çağrılır. Durum
/// `@Volatile` karşılığı olarak seri bir kuyrukla korunur; ağ işi ayrı bir `Task`'ta koşar.
final class SimilarityStreamer: @unchecked Sendable {

    /// İki gönderim arasındaki en kısa süre. Kare akışının kendisi değil, **en iyi karenin skoru
    /// yükseldiğinde** gönderiyoruz; yine de üst üste iyileşen bir seride istekler birikmesin
    /// diye alt sınır var.
    ///
    /// ⚠️ Trafik/pil optimizasyonu kapsam DIŞI (yeterli istatistik birikince özellik
    /// kapatılacak). Bu değer bir optimizasyon değil, sunucuyu kendi kendimize DDoS'lamama önlemi.
    /// Android `MIN_INTERVAL_MS` ile BİREBİR aynı.
    static let minIntervalMs: Double = 700

    /// Akış başına gönderim tavanı — Android `MAX_FRAMES` ile birebir aynı.
    static let maxFrames = 60

    private let flowId: String
    private let enclavePubKey: String

    /// Durum kilidi — video kuyruğu ile ağ Task'i arasındaki yarışları kapatır.
    private let lock = NSLock()

    private var seq = 0

    /// Oran freni yüzünden gönderilmeden elenen iyileşme sayısı — bir sonraki gönderimde
    /// raporlanıp sıfırlanır.
    ///
    /// Neden sayaç da kare değil: elenen karenin kendisini göndermek veriyi kareyle büyütürdü ve
    /// özelliğin amacı zaten trafik değil ölçüm.
    private var skippedSinceLastSend = 0

    /// Bitiş bildirimi akış başına TEK: ilk (gerçek) sebep kazanır — ekran hem başarı hem
    /// kapanış yolundan çağırıyor ve ikincisi onu "abandoned" ile ezerdi.
    private var releaseSent = false

    private var prepared = false
    /// Bir kez kapandıysa bir daha denenmez: her karede tekrar denemek, düşen bir sunucuyu döver.
    private var disabled = false
    private var inFlight = false
    private var lastSentAt: Double = 0

    /// Enclave'in onayladığı karenin selfie ve kırpma verisi — submit anında **2. aday** olur.
    ///
    /// ⚠️ Hangi karenin onaylandığını hatırlamak ŞART: enclave'in geçirdiği kare ile cihazın "en
    /// iyi" saydığı kare farklı olabilir (asıl ölçmek istediğimiz sapma tam olarak bu). Onaylanan
    /// kareyi unutup yalnız "onay aldık" bayrağını tutmak, submit'te enclave'e gönderilecek
    /// fotoğrafı kaybetmek olurdu.
    ///
    /// Android'de dosya YOLU tutuluyor; iOS'ta kare zaten bellekte `Data` olarak taşındığı için
    /// verinin kendisi tutulur (diske yazıp geri okumak gereksiz bir tur olurdu).
    private var _approvedSelfie: Data?
    private var _approvedCrop: Data?
    private var _approvedMetrics: DeviceFrameMetrics?
    /// Onaylanan karenin gönderildiği `seq` — final yükte 2. adayın `source_seq`'i olur.
    private var _approvedSeq: Int?
    /// En son GÖNDERİLEN karenin seq'i — 1. adayın `source_seq`'i (o kare de gönderilmişse).
    private var _lastSentSeq: Int?

    var approvedSelfie: Data? { lock.withLock { _approvedSelfie } }
    var approvedCrop: Data? { lock.withLock { _approvedCrop } }
    var approvedMetrics: DeviceFrameMetrics? { lock.withLock { _approvedMetrics } }
    var approvedSeq: Int? { lock.withLock { _approvedSeq } }
    var lastSentSeq: Int? { lock.withLock { _lastSentSeq } }

    /// Enclave en az bir kareyi benzerlikten geçirdi mi (submit'in ikinci yolu).
    var hasEnclaveApproval: Bool { lock.withLock { _approvedSelfie != nil } }

    /// Son enclave skoru — teşhis bloğuna yazılır (cihaz skoruyla kıyaslanamaz, farklı model).
    private var _lastEnclaveScore: Double?
    private var _lastPLive: Double?
    var lastEnclaveScore: Double? { lock.withLock { _lastEnclaveScore } }
    var lastPLive: Double? { lock.withLock { _lastPLive } }

    init(flowId: String, enclavePubKey: String) {
        self.flowId = flowId
        self.enclavePubKey = enclavePubKey
    }

    /// Akış başı hazırlık: DG2 bir kez enclave'e gider, enclave gömme vektörünü RAM'de tutar.
    /// Sonraki karelerde yalnız selfie + kırpma gider.
    ///
    /// Düşerse streaming sessizce kapanır — çağıran hiçbir şey yapmaz.
    func prepare(dg2Raw: Data?) {
        guard let dg2Raw, !dg2Raw.isEmpty else {
            lock.withLock { disabled = true }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = StreamingPreparePayload(dg2: dg2Raw.base64EncodedString())
                let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
                let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(json)
                let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: self.enclavePubKey)

                try await VerifyAPI.shared.streamingPrepare(
                    StreamingPrepareRequest(flowId: self.flowId, encryptedKey: encKey, aesBlob: aesBlob))

                self.lock.withLock { self.prepared = true }
                Log.info("Canlı benzerlik hazırlığı tamam", category: .liveness)
            } catch {
                self.lock.withLock { self.disabled = true }
                Log.info("Canlı benzerlik hazırlığı düştü: \(type(of: error))", category: .liveness)
            }
        }
    }

    /// Bir kareyi enclave'e gönderir. Çağıran bunu **en iyi karenin skoru her yükseldiğinde**
    /// çağırır.
    ///
    /// - Parameters:
    ///   - selfie: hizalanmış 112×112 PNG — enclave'in benzerlik için göreceği kare
    ///   - crop: AYNI karenin 2,7× geniş kırpması — enclave'in canlılık için göreceği kare
    ///
    /// ⚠️ İkisi AYNI kareden olmalıdır. Benzerliği bir kareden, canlılığı başkasından almak
    /// gerçek bir açıktır (saldırgan gerçek yüzü benzerliğe, canlı kırpmayı anti-spoof'a verir).
    ///
    /// Sessizce düşer: kuyruk doluysa, hazırlık tamamlanmadıysa, aralık dolmadıysa ya da tavan
    /// aşıldıysa hiçbir şey yapmaz.
    func submitFrame(selfie: Data, crop: Data?, metrics: DeviceFrameMetrics) {
        let now = Date().timeIntervalSince1970 * 1000

        // ⚠️ Elenen iyileşmeler SAYILIR: bu karenin skoru bir öncekinden iyiydi ama fren yüzünden
        // gönderilmedi. Saymazsak topladığımız dağılımın ne kadar yanlı olduğunu bilemeyiz.
        let sendPlan: (seq: Int, skipped: Int)? = lock.withLock {
            guard !disabled, prepared else { return nil }
            if inFlight || now - lastSentAt < Self.minIntervalMs {
                skippedSinceLastSend += 1
                return nil
            }
            // Tavan aşıldıysa artık ölçmüyoruz; saymak da yanıltıcı olurdu (sonsuza kadar artar).
            guard seq < Self.maxFrames else { return nil }
            inFlight = true
            lastSentAt = now
            let s = seq
            seq += 1
            _lastSentSeq = s
            // Sayaç gönderim ANINDA sıfırlanır: bu istek, o ana kadar elenenleri raporluyor.
            let skipped = skippedSinceLastSend
            skippedSinceLastSend = 0
            return (s, skipped)
        }
        guard let sendPlan else { return }
        let mySeq = sendPlan.seq

        Task { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.inFlight = false } }

            do {
                let payload = StreamingCheckPayload(
                    userSelfie: selfie.base64EncodedString(),
                    antiSpoofCrop: crop?.base64EncodedString() ?? "")
                let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
                let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(json)
                let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: self.enclavePubKey)

                let response = try await VerifyAPI.shared.streamingCheck(
                    StreamingCheckRequest(
                        flowId: self.flowId, encryptedKey: encKey, aesBlob: aesBlob,
                        seq: mySeq, deviceMetrics: {
                            var m = metrics
                            m.skippedCount = sendPlan.skipped
                            return m
                        }()))

                self.lock.withLock {
                    self._lastEnclaveScore = response.matchScore
                    self._lastPLive = response.pLive
                    if response.similarityPassed {
                        // ONAYLANAN KAREYİ HATIRLA — submit'te 2. aday olarak gider.
                        // Sonraki onaylar üzerine yazar: en son onaylanan kare, kullanıcının
                        // o ana kadarki en iyi durumunu temsil eder.
                        self._approvedSelfie = selfie
                        self._approvedCrop = crop
                        self._approvedMetrics = metrics
                        self._approvedSeq = mySeq
                    }
                }
            } catch APIClientError.rateLimited {
                // Oran sınırına takıldık — akışın geri kalanında susmak, 429 yağdırmaktan iyi.
                self.lock.withLock { self.disabled = true }
                Log.info("Canlı benzerlik oran sınırına takıldı — kapatıldı", category: .liveness)
            } catch {
                // Tek bir kare düşmesi streaming'i kapatmaz: ağ dalgalanması geçici olabilir.
                Log.info("Kare gönderilemedi: \(type(of: error))", category: .liveness)
            }
        }
    }

    /// Akış bitti — enclave RAM'indeki gömme vektörünü sil.
    ///
    /// Best-effort: çağrılmasa da TTL (15 dk) girdiyi toplar. Yine de çağrılır, çünkü enclave'de
    /// gereksiz duran her girdi tavana yaklaştırır.
    /// Akış bitti — enclave RAM'indeki gömme vektörünü sil ve akışın NASIL bittiğini bildir.
    ///
    /// - Parameter outcome: sabit küme — submitted | abandoned | timeout_gesture |
    ///   timeout_session | too_many_errors | match_failed | no_selfie.
    ///
    /// 🔴 `outcome` bu işin varlık sebebi olan vakayı görünür kılar: bir akış `abandoned` ya da
    /// `match_failed` ile biterken streaming satırlarında enclave skoru eşiği GEÇİYORSA, o
    /// kullanıcıyı cihazdaki ön eleme yüzünden kaybettik demektir.
    ///
    /// Yalnız BİR kez gönderilir (Android paritesi): ilk — gerçek — sebep kazanır.
    func release(outcome: String? = nil) {
        let shouldSend: Bool = lock.withLock {
            guard prepared, !releaseSent else { return false }
            releaseSent = true
            return true
        }
        guard shouldSend else { return }

        let id = flowId
        Task {
            // Temizlik başarısızlığı hiçbir şeyi bozmaz.
            try? await VerifyAPI.shared.streamingRelease(
                StreamingReleaseRequest(flowId: id, flowOutcome: outcome))
        }
    }

    /// Cihaz ölçülerini toplar — sunucu bunlara GÜVENMEZ, aralık kontrolünden geçirir ve
    /// geçersizse sessizce düşürür.
    ///
    /// Statik: ölçüler kare başına bir kez kurulur ve hem streaming isteğine hem de submit'teki
    /// aday satırına AYNI nesne olarak taşınır (Android `metricsOf` paritesi).
    /// Android'deki "VERSION_NAME+VERSION_CODE" biçiminin karşılığı — ölçüm satırında iki
    /// platformun sürümleri aynı şekilde okunsun diye.
    private static var appVersionWithBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)+\(build)"
    }

    static func metricsOf(
        deviceMatchScore: Int?, luma: Int?, sharpness: Int?, quality: Int?,
        yaw: Int?, pitch: Int?, roll: Int?, faceWidthRatio: Int?,
        gestureCount: Int?, wrongGestureCount: Int?, elapsedMs: Int?
    ) -> DeviceFrameMetrics {
        DeviceFrameMetrics(
            deviceMatchScore: deviceMatchScore,
            luma: luma,
            sharpness: sharpness,
            quality: quality,
            yaw: yaw,
            pitch: pitch,
            roll: roll,
            faceWidthRatio: faceWidthRatio,
            gestureCount: gestureCount,
            wrongGestureCount: wrongGestureCount,
            elapsedMs: elapsedMs,
            platform: "ios",
            appVersion: Self.appVersionWithBuild,
            // ⚠️ UIDevice.current.model DEĞİL: o her iPhone için sabit "iPhone" döner (model
            // SINIFI, model ADI değil) — ölçümde her cihaz aynı görünürdü. DeviceInfo utsname
            // kimliğini pazarlama adına çevirir ("iPhone 12"); Android tarafıyla da bu paritede.
            deviceModel: DeviceInfo.marketingName())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
