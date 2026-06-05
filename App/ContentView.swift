import SwiftUI
import Sentry

struct ContentView: View {
    @State private var didSendTestEvent = false
    @State private var selfTestResults: [SelfTestResult] = []
    @State private var runningSelfTest = false
    @State private var stage2Results: [SelfTestResult] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130, height: 130)

                    Text("VerifyBlind")
                        .font(.system(size: 34, weight: .semibold))

                    Text("iOS — Aşama 2: NFC")
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

                    // Dev/TestFlight Internal'da görünür, prod App Store'da gizli.
                    // ÇALIŞMA-ZAMANI kontrolü: TestFlight build'i Release config olduğu için
                    // `#if DEBUG` İŞE YARAMAZDI (DEBUG tanımsız → buton hiç görünmezdi).
                    if Config.appAttestEnvironment == .development {
                        stage2Section
                        selfTestSection
                    }
                }
                .padding()
            }
            .onAppear {
                Log.info("ContentView göründü", category: .flow)
            }
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

    // MARK: - Aşama 2 (NFC)

    private var stage2Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text("Stage 2 — NFC")
                .font(.headline)

            Text("Çip okuma cihazda fiziksel kartla test edilir. Deterministik mantık (MRZ anahtarı, challenge, payload eşleme) aşağıdaki self-test ile doğrulanır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink {
                NFCTestView()
            } label: {
                Label("NFC Çip Okuma Testi", systemImage: "wave.3.right")
            }
            .buttonStyle(.bordered)

            Button {
                stage2Results = Stage2SelfTest.runAll()
            } label: {
                Label("Stage 2 self-test çalıştır", systemImage: "checklist")
            }
            .buttonStyle(.bordered)

            ForEach(stage2Results) { resultRow($0) }

            if !stage2Results.isEmpty {
                let passed = stage2Results.filter { $0.passed }.count
                Text("\(passed)/\(stage2Results.count) passed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(passed == stage2Results.count ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 1 (Crypto + Network) self-test

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

            ForEach(selfTestResults) { resultRow($0) }

            if !selfTestResults.isEmpty {
                let passed = selfTestResults.filter { $0.passed }.count
                Text("\(passed)/\(selfTestResults.count) passed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(passed == selfTestResults.count ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ result: SelfTestResult) -> some View {
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
}

#Preview {
    ContentView()
}
