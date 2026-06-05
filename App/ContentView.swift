import SwiftUI
import Sentry

struct ContentView: View {
    @State private var didSendTestEvent = false
    #if DEBUG
    @State private var selfTestResults: [SelfTestResult] = []
    @State private var runningSelfTest = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130, height: 130)

                Text("VerifyBlind")
                    .font(.system(size: 34, weight: .semibold))

                Text("iOS — Aşama 1: Network + Crypto")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    row("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
                    row("Version", "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
                    row("API", Config.apiBaseURL.absoluteString)
                    row("AppAttest env", Config.appAttestEnvironment.rawValue)
                    row("Sentry", SentrySDK.isEnabled ? "açık" : "kapalı")
                }
                .font(.footnote.monospaced())
                .padding()
                .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    Log.info("Manuel test event — pipeline doğrulaması", category: .flow)
                    didSendTestEvent = true
                } label: {
                    Label(didSendTestEvent ? "Gönderildi" : "Sentry'e test event gönder", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(didSendTestEvent)

                #if DEBUG
                selfTestSection
                #endif
            }
            .padding()
        }
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

    #if DEBUG
    private var selfTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text("Stage 1 Self-Test")
                .font(.headline)

            Text("Kripto + DTO offline; app-config & handshake online. Sonuçlar Sentry'e loglanır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                runningSelfTest = true
                selfTestResults = []
                Task {
                    let results = await Stage1SelfTest.runAll()
                    selfTestResults = results
                    runningSelfTest = false
                }
            } label: {
                Label(runningSelfTest ? "Çalışıyor…" : "Self-test çalıştır", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .disabled(runningSelfTest)

            ForEach(selfTestResults) { result in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.footnote.weight(.medium))
                        Text(result.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            if !selfTestResults.isEmpty {
                let passed = selfTestResults.filter { $0.passed }.count
                Text("\(passed)/\(selfTestResults.count) passed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(passed == selfTestResults.count ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}

#Preview {
    ContentView()
}
