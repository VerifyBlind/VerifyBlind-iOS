import Foundation
import SwiftUI

@MainActor
final class ChatbotViewModel: ObservableObject {
    @Published var messages: [ChatTurn] = []
    @Published var input: String = ""
    @Published var isBusy: Bool = false
    @Published var requiresEmail: Bool = false
    @Published var errorMessage: String? = nil

    private var originalQuestion: String = ""

    private let storageKey = "verifyblind.chatbot.history"
    private let maxHistory = 10

    private var language: String {
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "tr"
        return pref.hasPrefix("en") ? "en" : "tr"
    }

    /// Karşılama ve ipucu metinleri kaynak dosyadan gelir — koda gömülü `language == "en" ? … : …`
    /// koşulları, `chatbot_*` anahtarları iki dilde de ÇEVRİLİ olmasına rağmen onları atlıyordu ve
    /// metin güncellemeleri sessizce Android'de kalıyordu. [language] artık yalnız sunucuya
    /// gönderilen istek alanı için kullanılıyor.
    var welcomeMessage: String { L.t("chatbot_welcome") }

    var placeholder: String {
        L.t(requiresEmail ? "chatbot_email_hint" : "chatbot_ask_hint")
    }

    init() {
        load()
        if messages.isEmpty {
            messages = [ChatTurn(role: "assistant", content: welcomeMessage)]
        }
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        errorMessage = nil

        if requiresEmail {
            await submitEmailCapture(email: text)
        } else {
            await sendChat(text: text)
        }
    }

    func resetConversation() {
        messages = [ChatTurn(role: "assistant", content: welcomeMessage)]
        requiresEmail = false
        originalQuestion = ""
        errorMessage = nil
        persist()
    }

    private func sendChat(text: String) async {
        messages.append(ChatTurn(role: "user", content: text))
        input = ""
        persist()
        isBusy = true
        defer { isBusy = false }

        let req = ChatRequest(
            messages: history(),
            turnstileToken: nil,
            source: "mobile",
            language: language,
            emailCapture: nil
        )

        do {
            let res = try await ChatbotService.shared.chat(req)
            messages.append(ChatTurn(role: "assistant", content: res.message))
            if res.requiresEmail {
                requiresEmail = true
                originalQuestion = text
            }
            persist()
        } catch {
            messages.append(ChatTurn(role: "assistant", content: networkErrorMessage))
            errorMessage = UserFacingError.message(for: error)
            persist()
        }
    }

    private func submitEmailCapture(email: String) async {
        guard isValidEmail(email) else {
            errorMessage = L.t("chatbot_invalid_email")
            return
        }

        messages.append(ChatTurn(role: "user", content: email))
        input = ""
        persist()
        isBusy = true
        defer { isBusy = false }

        let req = ChatRequest(
            messages: history(),
            turnstileToken: nil,
            source: "mobile",
            language: language,
            emailCapture: ChatEmailCapture(email: email, originalQuestion: originalQuestion)
        )

        do {
            let res = try await ChatbotService.shared.chat(req)
            messages.append(ChatTurn(role: "assistant", content: res.message))
            requiresEmail = false
            originalQuestion = ""
            persist()
        } catch {
            messages.append(ChatTurn(role: "assistant", content: networkErrorMessage))
            errorMessage = UserFacingError.message(for: error)
            persist()
        }
    }

    private func history() -> [ChatMessageDto] {
        let lastN = messages.suffix(maxHistory * 2 + 1)
        return lastN.map { ChatMessageDto(role: $0.role, content: $0.content) }
    }

    private var networkErrorMessage: String { L.t("chatbot_network_error") }

    private func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ChatTurn].self, from: data),
              !decoded.isEmpty else {
            return
        }
        messages = Array(decoded.suffix(maxHistory * 2 + 1))
    }

    private func persist() {
        let trimmed = Array(messages.suffix(maxHistory * 2 + 1))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
