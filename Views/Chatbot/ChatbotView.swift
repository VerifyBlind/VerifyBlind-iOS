import SwiftUI

struct ChatbotView: View {
    @StateObject private var vm = ChatbotViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            composer
        }
        .background(Color(.systemBackground))
        .navigationBarHidden(true)
        .alert(item: alertBinding) { msg in
            Alert(title: Text(msg.text))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("Geri")

            VStack(alignment: .leading, spacing: 2) {
                Text("Destek Asistanı")
                    .font(.system(size: 17, weight: .semibold))
                Text("VerifyBlind")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { vm.resetConversation() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .medium))
            }
            .accessibilityLabel("Yeni konuşma")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.messages) { turn in
                        bubble(for: turn).id(turn.id)
                    }
                    if vm.isBusy {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.8)
                            Text("Yazıyor…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for turn: ChatTurn) -> some View {
        HStack {
            if turn.isUser { Spacer(minLength: 32) }
            Text(turn.content)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(turn.isUser ? Color.accentColor : Color(.tertiarySystemFill))
                .foregroundStyle(turn.isUser ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 280, alignment: turn.isUser ? .trailing : .leading)
            if !turn.isUser { Spacer(minLength: 32) }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(vm.placeholder, text: $vm.input, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($inputFocused)
                .keyboardType(vm.requiresEmail ? .emailAddress : .default)
                .textInputAutocapitalization(vm.requiresEmail ? .never : .sentences)
                .submitLabel(.send)
                .onSubmit { Task { await vm.send() } }

            Button(action: { Task { await vm.send() } }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isBusy
                                ? Color.gray.opacity(0.4)
                                : Color.accentColor)
                    .clipShape(Circle())
            }
            .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isBusy)
            .accessibilityLabel("Gönder")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Alert binding

    private struct ErrorPayload: Identifiable {
        let id = UUID()
        let text: String
    }

    private var alertBinding: Binding<ErrorPayload?> {
        Binding(
            get: { vm.errorMessage.map { ErrorPayload(text: $0) } },
            set: { _ in vm.errorMessage = nil }
        )
    }
}

#Preview {
    ChatbotView()
}
