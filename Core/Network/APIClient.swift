import Foundation

/// URLSession tabanlı HTTP istemcisi — Android `RetrofitClient` + interceptor zincirinin eşdeğeri.
///
/// - **Cert pinning**: `CertificatePinningDelegate` (pin yoksa varsayılan TLS — Android `USE_LOCAL_API` davranışı).
/// - **Retry**: geçici hatalarda 2 retry, exponential backoff (500/1000 ms) — Android `NetworkRetryInterceptor`.
/// - **Accept-Language**: `tr`/`en` — Android `LocaleHeaderInterceptor`.
/// - **Base URL**: `Config.apiBaseURL`'in origin'i; her endpoint tam path taşır.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let origin: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let maxRetries = 2
    private let initialBackoffNanos: UInt64 = 500_000_000 // 500 ms

    init(baseURL: URL = Config.apiBaseURL, pins: [String] = Config.certPins) {
        self.origin = APIClient.origin(of: baseURL)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60          // Android connectTimeout = 60s
        cfg.timeoutIntervalForResource = 300        // Android read/write = ∞; pratik üst sınır
        cfg.waitsForConnectivity = false

        let delegate = CertificatePinningDelegate(pins: pins, host: baseURL.host)
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Kolaylık metotları (VerifyAPI bunları kullanır)

    func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        try await send(Endpoint(method: .get, path: path, headers: headers))
    }

    func post<B: Encodable, T: Decodable>(_ path: String, body: B, headers: [String: String] = [:]) async throws -> T {
        let endpoint = Endpoint(method: .post, path: path, body: try encode(body), headers: headers)
        return try await send(endpoint)
    }

    /// Gövdesiz yanıt dönen POST'lar (Android `Response<Unit>`).
    func postNoContent<B: Encodable>(_ path: String, body: B, headers: [String: String] = [:]) async throws {
        let endpoint = Endpoint(method: .post, path: path, body: try encode(body), headers: headers)
        _ = try await sendRaw(endpoint)
    }

    // MARK: - Çekirdek

    func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let data = try await sendRaw(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch let firstError {
            // Bazı uçlar gövdeyi JSON-string'e sarılı döndürür (ASP.NET `StatusCode(code, stringObject)`
            // → ObjectResult string'i çift-encode edebiliyor → `"{...}"`). Önce String çöz, sonra
            // içindeki JSON'ı T'ye decode et. (Register/login success yolları bu kalıbı kullanıyor.)
            if let wrapped = try? decoder.decode(String.self, from: data),
               let inner = wrapped.data(using: .utf8),
               let value = try? decoder.decode(T.self, from: inner) {
                Log.info("APIClient: \(T.self) çift-encode çözüldü (string-sarmalı gövde)", category: .network)
                return value
            }
            Log.error("APIClient: \(T.self) decode başarısız", error: firstError, category: .network)
            throw APIClientError.decoding
        }
    }

    /// İsteği gönderir, retry/backoff uygular, başarılı gövdeyi ham döndürür.
    func sendRaw(_ endpoint: Endpoint) async throws -> Data {
        let request = buildRequest(endpoint)
        var attempt = 0

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIClientError.network("HTTP olmayan yanıt")
                }

                // 503 → geçici, retry (Android: Cloudflare/altyapı).
                if http.statusCode == 503, attempt < maxRetries {
                    try await Task.sleep(nanoseconds: backoff(attempt))
                    attempt += 1
                    continue
                }

                guard (200..<300).contains(http.statusCode) else {
                    throw apiError(status: http.statusCode, data: data)
                }
                return data

            } catch let urlError as URLError {
                if Self.isRetriable(urlError), attempt < maxRetries {
                    Log.warning("APIClient: retry (\(attempt + 1)/\(maxRetries)) — \(urlError.code)", category: .network)
                    try await Task.sleep(nanoseconds: backoff(attempt))
                    attempt += 1
                    continue
                }
                Log.error("APIClient: ağ hatası (\(endpoint.path))", error: urlError, category: .network)
                throw APIClientError.network("\(urlError.code)")
            }
        }
    }

    // MARK: - Yardımcılar

    private func encode<B: Encodable>(_ body: B) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            Log.error("APIClient: istek gövdesi encode başarısız", error: error, category: .network)
            throw APIClientError.decoding
        }
    }

    private func buildRequest(_ endpoint: Endpoint) -> URLRequest {
        let url = origin.appendingPathComponent(endpoint.path)
        var req = URLRequest(url: url)
        req.httpMethod = endpoint.method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.acceptLanguage(), forHTTPHeaderField: "Accept-Language")
        for (key, value) in endpoint.headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        if let body = endpoint.body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func apiError(status: Int, data: Data) -> APIClientError {
        if let body = try? decoder.decode(APIErrorBody.self, from: data),
           body.error != nil || body.code != nil || body.details != nil {
            return .http(status, body)
        }
        // JSON değilse: kısa, HTML olmayan gövdeyi mesaj olarak taşı (Android parseApiError fallback).
        if let text = String(data: data, encoding: .utf8),
           text.count < 500,
           !text.lowercased().contains("<html") {
            return .http(status, APIErrorBody(error: text.trimmingCharacters(in: .whitespacesAndNewlines), code: nil, details: nil))
        }
        return .http(status, nil)
    }

    private func backoff(_ attempt: Int) -> UInt64 {
        initialBackoffNanos << attempt // 500ms, 1000ms
    }

    /// Android `NetworkRetryInterceptor`: UnknownHost / ConnectException / SSLHandshake eşdeğerleri.
    static func isRetriable(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Android `LocaleHeaderInterceptor`: sistem dili tr → "tr", diğer hepsi → "en".
    static func acceptLanguage() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code == "tr" ? "tr" : "en"
    }

    /// `Config.apiBaseURL`'in origin'i (scheme://host[:port]) — path bileşeni atılır.
    static func origin(of url: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = url.host
        comps.port = url.port
        return comps.url ?? url
    }
}
