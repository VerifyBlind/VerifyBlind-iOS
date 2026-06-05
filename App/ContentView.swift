import SwiftUI
import Sentry

struct ContentView: View {
    @State private var didSendTestEvent = false
    @State private var sendResult = ""

    /// DSN public değer — Codemagic/Sentry karşılaştırması için tam göster.
    private var dsnDisplay: String {
        let dsn = Config.sentryDSN
        guard !dsn.isEmpty else { return "BOŞ" }
        // host + project path parçası (public key'i kısalt)
        if let at = dsn.firstIndex(of: "@") {
            return "…@" + dsn[dsn.index(after: at)...]
        }
        return dsn
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 130, height: 130)

            Text("VerifyBlind")
                .font(.system(size: 34, weight: .semibold))

            Text("iOS — Aşama 0 boş iskelet")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                row("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
                row("Version", "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
                row("API", Config.apiBaseURL.absoluteString)
                row("AppAttest env", Config.appAttestEnvironment.rawValue)
                row("Sentry SDK", SentrySDK.isEnabled ? "ENABLED" : "DISABLED")
                row("DSN", dsnDisplay)
                if !sendResult.isEmpty {
                    row("Sonuç", sendResult)
                }
            }
            .font(.footnote.monospaced())
            .padding()
            .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Button {
                sendResult = "gönderiliyor…"
                didSendTestEvent = true
                Task { await sendRawEnvelope() }
            } label: {
                Label(didSendTestEvent ? "Gönderildi" : "Sentry'e RAW test gönder", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(didSendTestEvent)

            Spacer()
        }
        .padding()
        .onAppear {
            Log.info("ContentView göründü", category: .flow)
        }
    }

    /// SDK'yı bypass edip Sentry envelope endpoint'ine ham POST atar.
    /// HTTP status'u ekranda gösterir → transport/DSN/network sorununu kesin ayırır.
    private func sendRawEnvelope() async {
        let dsn = Config.sentryDSN
        guard let url = URL(string: dsn),
              let key = url.user,
              let host = url.host else {
            await MainActor.run { sendResult = "DSN parse FAIL" }
            return
        }
        let projectId = url.lastPathComponent
        guard let envelopeURL = URL(string: "https://\(host)/api/\(projectId)/envelope/") else {
            await MainActor.run { sendResult = "URL FAIL" }
            return
        }

        let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let header = "{\"event_id\":\"\(eventId)\",\"dsn\":\"\(dsn)\"}"
        let itemHeader = "{\"type\":\"event\"}"
        let payload = "{\"message\":\"RAW HTTP test\",\"level\":\"error\",\"platform\":\"cocoa\"}"
        let body = "\(header)\n\(itemHeader)\n\(payload)\n"

        var req = URLRequest(url: envelopeURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        req.setValue("Sentry sentry_version=7, sentry_key=\(key), sentry_client=verifyblind-manual/1.0",
                     forHTTPHeaderField: "X-Sentry-Auth")
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8)?.prefix(50) ?? ""
            await MainActor.run { sendResult = "HTTP \(code) \(respStr)" }
        } catch {
            await MainActor.run { sendResult = "NET ERR: \(error.localizedDescription.prefix(50))" }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

#Preview {
    ContentView()
}
