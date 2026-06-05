import Foundation
import Security

/// TLS sertifika pinning — Android OkHttp `CertificatePinner` eşdeğeri.
///
/// Pin formatı `sha256/<base64(SPKI-SHA256)>` (OkHttp/HPKP standardı). Sunucu zincirindeki
/// herhangi bir sertifikanın SubjectPublicKeyInfo SHA-256'sı `Config.certPins` ile eşleşmeli.
///
/// **`pins` boşsa pinning atlanır** (yalnızca standart TLS doğrulaması) — Android'in
/// `USE_LOCAL_API` modunda pinning'i kapatmasının karşılığı (lokal/dev placeholder pin'leri boş).
///
/// Not: SPKI hash'i şu an RSA anahtarlar için hesaplanır (`RSAKey.spkiSHA256`). VerifyBlind
/// sunucu sertifikası RSA'dır (Let's Encrypt/ISRG). EC anahtar gerekirse `RSAKey` genişletilmeli.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate {

    private let pins: Set<String>
    private let host: String?

    init(pins: [String], host: String?) {
        self.pins = Set(pins)
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

        // Pin yok → varsayılan TLS doğrulaması (lokal/dev).
        guard !pins.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
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
