import Foundation

/// Tek bir HTTP isteğini tanımlayan hafif tip (Android Retrofit `KimlikApi` imzalarının eşdeğeri).
///
/// `path` host-root'a görelidir (örn. `api/Verify/handshake`). `APIClient`, `Config.apiBaseURL`'in
/// **origin'ine** (scheme+host[+port]) ekler — böylece tabandaki `…/api/verify/` ile host-root
/// arasındaki belirsizlik ortadan kalkar.
struct Endpoint {
    enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    let method: Method
    let path: String
    var body: Data? = nil
    var headers: [String: String] = [:]
}

/// Ağ katmanı hataları (Android `ApiError` + `parseApiError` mantığının eşdeğeri).
enum APIClientError: Error, LocalizedError {
    case network(String)
    case http(Int, APIErrorBody?)
    /// 429 — sunucu Retry-After header'ı gönderirse saniye cinsinden taşır (Android `rateLimitMessageOrNull`).
    case rateLimited(retryAfterSeconds: Int?)
    case decoding

    var errorDescription: String? {
        switch self {
        case .network(let m):
            return "Ağ hatası: \(m)"
        case .http(let status, let body):
            let detail = [body?.error, body?.details].compactMap { $0 }.joined(separator: " — ")
            return detail.isEmpty ? "Sunucu hatası (\(status))" : "Sunucu hatası (\(status)): \(detail)"
        case .rateLimited(let secs):
            guard let secs, secs > 0 else { return L.t("error_rate_limited_generic") }
            return secs >= 60
                ? L.t("error_rate_limited_minutes", (secs + 59) / 60)   // ceil → dakika
                : L.t("error_rate_limited_seconds", secs)
        case .decoding:
            return "Yanıt çözümlenemedi."
        }
    }
}
