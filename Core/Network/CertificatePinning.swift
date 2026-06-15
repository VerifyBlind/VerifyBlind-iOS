import Foundation
import Security

/// TLS sertifika pinning — Android OkHttp `CertificatePinner` eşdeğeri.
///
/// Pin'ler KODA GÖMÜLÜ tek kaynak (`pinnedPublicKeys`). Pin gizli değil (public-key SPKI-SHA256
/// hash'i) ve her pin değişikliği zaten yeni build + mağaza yayını gerektirir → secret/xcconfig
/// indirection'ı fayda sağlamadığı için kaldırıldı (Android'in committed `verifyblind.properties`
/// tek-kaynak modeliyle aynı). Pin formatı `sha256/<base64(SPKI-SHA256)>` (OkHttp/HPKP standardı):
/// sunucu zincirindeki herhangi bir sertifikanın SPKI SHA-256'sı pin'lerden biriyle eşleşmeli.
///
/// api.verifyblind.com = Let's Encrypt **ECDSA**: leaf → E8 (ara) → ISRG Root X2 (kök). Leaf
/// pinlenmez (~60-90 günde döner); E8 + X2 yıllarca sabit. Değerler 2026-06-15 canlı sertifikadan.
/// SPKI hash'i RSA + EC için `RSAKey.spkiSHA256` ile hesaplanır.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate {

    /// Sabitlenen public-key SPKI-SHA256 pin'leri — TEK KAYNAK.
    static let pinnedPublicKeys: Set<String> = [
        "sha256/iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // Let's Encrypt E8 (ECDSA ara)
        "sha256/diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="   // ISRG Root X2 (ECDSA kök)
    ]

    private let pins: Set<String>
    private let host: String?

    init(host: String?, pins: Set<String> = CertificatePinningDelegate.pinnedPublicKeys) {
        self.pins = pins
        self.host = host
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Pin seti koda gömülü → normalde asla boş olmaz; boşsa güvenli tarafta kal (reddet).
        guard !pins.isEmpty else {
            Log.error("Cert pinning: pin seti boş — bağlantı reddedildi (host: \(host ?? "?"))", category: .network)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Önce zincirin standart geçerliliği (süre/CA/hostname).
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            Log.error("Cert pinning: trust değerlendirmesi başarısız (host: \(host ?? "?"))", category: .network)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if matchesPin(serverTrust) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            Log.error("Cert pinning: SPKI pin uyuşmadı (host: \(host ?? "?"))", category: .network)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func matchesPin(_ trust: SecTrust) -> Bool {
        for cert in certificateChain(of: trust) {
            guard let key = SecCertificateCopyKey(cert),
                  let spkiHash = RSAKey.spkiSHA256(of: key) else { continue }
            let pin = "sha256/" + spkiHash.base64EncodedString()
            if pins.contains(pin) { return true }
        }
        return false
    }

    private func certificateChain(of trust: SecTrust) -> [SecCertificate] {
        if #available(iOS 15.0, *) {
            return (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        } else {
            let count = SecTrustGetCertificateCount(trust)
            return (0..<count).compactMap { SecTrustGetCertificateAtIndex(trust, $0) }
        }
    }
}
