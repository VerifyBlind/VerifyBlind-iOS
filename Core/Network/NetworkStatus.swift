import Foundation
import Network

/// "Cihazın şu anda çalışan bir internet bağlantısı var mı?" — TEK kaynak (Android `NetworkStatus` paritesi).
///
/// Neden gerekli: bir isteğin taşıma katmanında düşmesi iki BAMBAŞKA durumu aynı hatayla temsil eder:
///  1) Kullanıcının interneti yok  → bizim arızamız DEĞİL; Sentry'ye gitmemeli (ücretsiz plan kotası
///     çevresel olaylarla yanıyordu — Android'de VERIFYBLIND-ANDROID-12, iOS'ta VERIFYBLIND-IOS-3G/3H).
///  2) İnternet var ama bize ulaşılamıyor → gerçek sinyal (DNS/edge/origin arızası) → warning.
///
/// `NWPathMonitor` arka planda bir kez başlatılır; sorgu anında bloklamaz. İzin gerekmez.
final class NetworkStatus: @unchecked Sendable {

    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.verifyblind.networkstatus")
    private let lock = NSLock()

    /// Monitör ilk yolu bildirene kadar "bağlı" varsayılır: bilinmeyeni "internet yok" saymak
    /// gerçek arızaları sessizce yutardı. Yani bu sınıf yalnız KESİN offline'da `false` döner.
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = (path.status == .satisfied)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    var isOffline: Bool { !isOnline }

    // MARK: - Hata sınıflandırma

    /// Hata, HTTP cevabı ALINAMADAN düşen bir taşıma hatası mı (DNS/TCP/TLS/timeout/no-internet)?
    ///
    /// Android `ServerErrorMessages.isTransportFailure` karşılığı. Ayrım teşhis için kritik:
    /// her hatayı "bağlantı sorunu" saymak, gerçek bir kod arızasını kullanıcı tarafında ağ
    /// sorunu gibi gösterir.
    static func isTransportFailure(_ error: Error?) -> Bool {
        isTransportFailure(error, depth: 0)
    }

    private static func isTransportFailure(_ error: Error?, depth: Int) -> Bool {
        guard let error, depth < 5 else { return false }   // döngüsel sebep zincirine karşı tavan
        if let api = error as? APIClientError, case .network = api { return true }
        if error is URLError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain { return true }
        // Sarmalanmış olabilir (Task/actor sınırlarında yeniden fırlatılır).
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransportFailure(underlying, depth: depth + 1)
        }
        return false
    }

    /// Taşıma hatası VE cihazda internet yok → kullanıcının uçak modu; raporlanacak bir arıza değil.
    static func isOfflineTransportFailure(_ error: Error?) -> Bool {
        isTransportFailure(error) && shared.isOffline
    }
}
