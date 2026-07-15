import Foundation

struct ChatTurn: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String      // "user" | "assistant"
    let content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    var isUser: Bool { role == "user" }
}

struct ChatMessageDto: Codable {
    let role: String
    let content: String
}

struct ChatEmailCapture: Codable {
    let email: String
    let originalQuestion: String

    enum CodingKeys: String, CodingKey {
        case email
        case originalQuestion = "original_question"
    }
}

struct ChatRequest: Codable {
    let messages: [ChatMessageDto]
    let turnstileToken: String?
    let source: String        // "mobile"
    let language: String?
    let emailCapture: ChatEmailCapture?

    enum CodingKeys: String, CodingKey {
        case messages
        case turnstileToken = "turnstile_token"
        case source
        case language
        case emailCapture = "email_capture"
    }
}

struct ChatResponse: Codable {
    let message: String
    let requiresEmail: Bool
    let ticketCreated: Bool
    let ticketId: Int?

    enum CodingKeys: String, CodingKey {
        case message
        case requiresEmail = "requires_email"
        case ticketCreated = "ticket_created"
        case ticketId = "ticket_id"
    }
}
