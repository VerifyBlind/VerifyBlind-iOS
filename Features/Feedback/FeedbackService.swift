import Foundation

/// "Bize Ulaşın" / geri bildirim isteği — landing formuyla aynı `POST /api/feedback` sözleşmesi.
/// `source = "mobile"` gönderildiğinde sunucu Turnstile'ı atlar (uygulamada captcha yok).
/// `turnstile_token` mobilde gerekmediği için kodlanmaz.
struct FeedbackRequest: Encodable {
    let name: String
    let email: String
    let subject: String
    let message: String
    let source: String        // "mobile"
    let language: String?
}

private struct FeedbackErrorBody: Decodable {
    let error: String?
    let code: String?
}

enum FeedbackError: Error {
    case network
    /// HTTP başarısız — `code` sunucudan gelen makine-okur hata kodu (MISSING_FIELDS, INVALID_EMAIL, …).
    case http(status: Int, code: String?)
}

/// Android `KimlikApi.sendFeedback` eşdeğeri. Chatbot ile aynı desen: bağımsız `URLSession`,
/// host-root path (`APIClient.origin(of:)`), pin'siz (kimlik verisi taşımaz).
final class FeedbackService {
    static let shared = FeedbackService()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    func send(_ payload: FeedbackRequest) async throws {
        // Taban `…/api/verify/` olsa bile doğru host-root üretilir (bkz. ChatbotService).
        let endpoint = APIClient.origin(of: Config.apiBaseURL).appendingPathComponent("api/feedback")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? encoder.encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw FeedbackError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.network
        }

        if !(200..<300).contains(http.statusCode) {
            let code = (try? decoder.decode(FeedbackErrorBody.self, from: data))?.code
            throw FeedbackError.http(status: http.statusCode, code: code)
        }
    }
}
