import Foundation

enum ChatbotServiceError: Error, LocalizedError {
    case network
    case http(Int, String?)
    case decoding

    var errorDescription: String? {
        switch self {
        case .network:           return "Bağlantı hatası."
        case .http(let s, let m): return "Sunucu hatası (\(s)): \(m ?? "")"
        case .decoding:          return "Yanıt çözümlenemedi."
        }
    }
}

final class ChatbotService {
    static let shared = ChatbotService()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func chat(_ payload: ChatRequest) async throws -> ChatResponse {
        let endpoint = Config.apiBaseURL.appendingPathComponent("api/chatbot/chat")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            req.httpBody = try encoder.encode(payload)
        } catch {
            throw ChatbotServiceError.decoding
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ChatbotServiceError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatbotServiceError.network
        }

        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw ChatbotServiceError.http(http.statusCode, body)
        }

        do {
            return try decoder.decode(ChatResponse.self, from: data)
        } catch {
            throw ChatbotServiceError.decoding
        }
    }
}
