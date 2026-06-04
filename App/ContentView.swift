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
                guard SentrySDK.isEnabled else {
                    sendResult = "SDK DISABLED — gitmedi"
                    didSendTestEvent = true
                    return
                }
                // En basit capture — scope callback yok
                let eventId = SentrySDK.capture(message: "Manuel test event — \(Date())")
                SentrySDK.flush(timeout: 5)
                let idStr = eventId.sentryIdString
                sendResult = idStr.hasPrefix("00000000") ? "DROP (empty id)" : "OK: \(idStr.prefix(8))"
                didSendTestEvent = true
            } label: {
                Label(didSendTestEvent ? "Gönderildi" : "Sentry'e test event gönder", systemImage: "paperplane.fill")
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
