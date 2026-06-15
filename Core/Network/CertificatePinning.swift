import Foundation
import Security

/// TLS sertifika pinning — Android OkHttp `CertificatePinner` eşdeğeri.
///
/// Pin formatı `sha256/<base64(SPKI-SHA256)>` (OkHttp/HPKP standardı). Sunucu zincirindeki
/// herhangi bir sertifikanın SubjectPublicKeyInfo SHA-256'sı `Config.certPins` ile eşleşmeli.
///
/// **`pins` boşsa**: prod'da (`Config.appAttestEnvironment == .production`) bağlantı fail-closed
/// reddedilir — sessiz default-TLS'e DÜŞMEZ (Y-8a); dev/local'de standart TLS'e düşer (Android
/// `USE_LOCAL_API` karşılığı). Koda gömülü `backupPins`, xcconfig CERT_PIN_* boş kalsa bile prod
/// pinning'ini ayakta tutar.
///
/// Not: SPKI hash'i şu an RSA anahtarlar için hesaplanır (`RSAKey.spkiSHA256`). VerifyBlind
/// sunucu sertifikası RSA'dır (Let's Encrypt/ISRG). EC anahtar gerekirse `RSAKey` genişletilmeli.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate {

    /// Koda gömülü YEDEK pin(ler) — xcconfig CERT_PIN_* boş kalsa bile prod'da pinning'in sessizce
    /// kapanmasını engeller (Y-8a). Sunucu zincirindeki SABİT sertifikaların SPKI-SHA256 pin'i.
    /// api.verifyblind.com artık Let's Encrypt ECDSA: leaf → E8 (ara) → ISRG Root X2 (kök).
    /// Leaf pinlenmez (~60-90 günde döner); E8 + X2 yıllarca sabit. 2026-06-15 canlı sertifikadan çıkarıldı.
    private static let backupPins: Set<String> = [
        "sha256/iFvwVyJSxnQdyaUvUERIf+8qk7gRze3612JMwoO3zdU=",  // Let's Encrypt E8 (ECDSA ara)
        "sha256/diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="   // ISRG Root X2 (ECDSA kök)
    ]

    private let pins: Set<String>
    private let isProduction: Bool
    private let host: String?

    init(pins: [String], host: String?,
         isProduction: Bool = (Config.appAttestEnvironment == .production)) {
        // Yapılandırılmış pin'ler + koda gömülü yedek pin'ler (HPKP backup-pin pratiği; cert rotasyonu).
        self.pins = Set(pins).union(CertificatePinningDelegate.backupPins)
        self.isProduction = isProduction
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

        // Pin yok → prod'da fail-closed (sessiz default-TLS'e DÜŞME); dev/local'de varsayılan TLS.
        guard !pins.isEmpty else {
            if isProduction {
                Log.error("Cert pinning: prod'da pin yok — bağlantı reddedildi (fail-closed). " +
                          "backupPins / CERT_PIN_* doldurulmalı (host: \(host ?? "?"))", category: .network)
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
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
