import Foundation

/// QR payload ayrıştırma — Android `MainActivity.handleQrDetected` birebir mantığı.
/// Öncelik 1: deeplink URL (`https://app.verifyblind.com/request?nonce=...&pk_hash=...`).
/// Öncelik 2: JSON fallback (`{"nonce":"...","pk_hash":"..."}`).
enum QRPayloadParser {
    struct Result: Equatable {
        let nonce: String
        let pkHash: String?
        /// App-to-app deeplink'teki opsiyonel geri-dönüş URL'i (ör. "verifyblinddemo://callback").
        /// Yalnız deeplink akışında anlamlı; taranan QR'da genelde yoktur.
        var returnUrl: String? = nil
    }

    /// Doğrulama bağlantısının kabul edildiği tek adres. Android `handleQrDetected` / `handleIntent`
    /// şema + host (+ deeplink'te `/request`) kontrolü yapıyordu; iOS ise HERHANGİ bir URL'deki
    /// `nonce` parametresini kabul ediyordu. Nonce'u sunucu zaten doğruluyor, yani bu bir kimlik
    /// açığı değil; ama başka bir siteye ait QR'ı "geçersiz kod" yerine sessizce akışa sokmak
    /// yanlış (parite denetimi 2026-09-03, D-1).
    static let verifyHost = "app.verifyblind.com"
    static let verifyPathPrefix = "/request"

    /// URL bizim doğrulama bağlantımız mı (https + host + /request)? Deep-link girişinde de
    /// kullanılır ki iki yol AYNI kuralı paylaşsın.
    static func isVerifyURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == verifyHost
            && url.path.hasPrefix(verifyPathPrefix)
    }

    static func parse(_ payload: String) -> Result? {
        // 1) Deeplink URL — yalnız kendi doğrulama adresimiz.
        if let comps = URLComponents(string: payload), let items = comps.queryItems,
           let url = comps.url, isVerifyURL(url) {
            if let nonce = items.first(where: { $0.name == "nonce" })?.value, !nonce.isEmpty {
                let pk = items.first(where: { $0.name == "pk_hash" })?.value
                let ret = items.first(where: { $0.name == "return" })?.value
                return Result(nonce: nonce, pkHash: (pk?.isEmpty == false) ? pk : nil,
                              returnUrl: (ret?.isEmpty == false) ? ret : nil)
            }
        }
        // 2) JSON fallback
        if let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nonce = obj["nonce"] as? String, !nonce.isEmpty {
            let pk = obj["pk_hash"] as? String
            return Result(nonce: nonce, pkHash: (pk?.isEmpty == false) ? pk : nil)
        }
        return nil
    }
}
