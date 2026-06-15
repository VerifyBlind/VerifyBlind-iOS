#if DEBUG
import SwiftUI
import Sentry

/// Geliştirici teşhis ekranı — eski ContentView self-test içeriği buraya taşındı.
/// SADECE `Config.appAttestEnvironment == .development` iken Wallet'tan (logo'ya uzun bas) açılır;
/// prod App Store'da erişilemez. Codemagic build'ine test adımı EKLEMEZ ([[feedback_ios_codemagic_no_ci_tests]]).
struct DevMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didSendTestEvent = false
    @State private var selfTestResults: [SelfTestResult] = []
    @State private var runningSelfTest = false
    @State private var stage2Results: [SelfTestResult] = []
    @State private var stage3Results: [SelfTestResult] = []
    @State private var stage4Results: [SelfTestResult] = []
    @State private var stage5Results: [SelfTestResult] = []
    @State private var stage6Results: [SelfTestResult] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
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

                    crashTestSection

                    stage6Section
                    stage5Section
                    stage4Section
                    stage3Section
                    stage2Section
                    selfTestSection
                }
                .padding()
            }
            .navigationTitle("Dev Menü")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Kapat") { dismiss() } } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: - Crash testi (Sentry teslim doğrulaması)

    /// Crash raporu cihazda gerçekten Sentry'e gidiyor mu? Düğmeye bas → uygulama çöker →
    /// TEKRAR AÇ → rapor bir sonraki açılışta otomatik gönderilir (`onCrashedLastRun` log'u görünür).
    private var crashTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Crash Testi — Sentry teslimi").font(.headline)
            Text("Crash anında gönderilemez; SDK diske yazar, UYGULAMAYI TEKRAR AÇINCA otomatik gönderir. Test sonrası uygulamayı yeniden başlat ve Sentry panosunu kontrol et.")
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) {
                Log.breadcrumb("Dev menü: SentrySDK.crash() tetiklendi", category: .app)
                SentrySDK.crash()   // gerçek hard crash (sinyal yolu)
            } label: {
                Label("Force Crash (SentrySDK.crash)", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                Log.breadcrumb("Dev menü: Swift nil-unwrap crash tetiklendi", category: .app)
                let nilValue: String? = nil
                _ = nilValue!   // Swift fatal: force-unwrap nil → sinyal yolu, stack trace yakalanır
            } label: {
                Label("Force Crash (Swift nil-unwrap)", systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 6 (Settings/Help/Security/Consent + App Attest)

    private var stage6Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 6 — Settings/Help/Security + App Attest").font(.headline)
            Text("App Attest clientDataHash konvansiyonu (sunucu paritesi), token zarf round-trip, enroll anahtar şeması, enclave PCR0 CBOR çıkarımı (+ graceful), dil tercihi. Sonuçlar Sentry'e loglanır.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                stage6Results = Stage6SelfTest.runAll()
                let passed = stage6Results.filter { $0.passed }.count
                Log.info("Stage6 self-test: \(passed)/\(stage6Results.count) passed", category: .flow)
            } label: {
                Label("Stage 6 self-test çalıştır", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            ForEach(stage6Results) { resultRow($0) }
            summary(stage6Results)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 5 (Backup)

    private var stage5Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 5 — Backup (Dropbox / Google Drive)").font(.headline)
            Text("personId-AES-GCM çapraz-platform şifreleme, bulut yedek JSON şema/anahtar paritesi, GRDB DB iCloud yedeğinden hariç + keychain ThisDeviceOnly, HistoryRepository sync zinciri. Sonuçlar Sentry'e loglanır.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                stage5Results = Stage5SelfTest.runAll()
            } label: {
                Label("Stage 5 self-test çalıştır", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            ForEach(stage5Results) { resultRow($0) }
            summary(stage5Results)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 4 (Storage / GRDB / payload)

    private var stage4Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 4 — Storage / GRDB / Payload").font(.headline)
            Text("KeychainKeyStore OAEP-SHA1 round-trip, TicketStore, GRDB history, SecureStore, maskeleme, QR/deeplink parse, JSON şekilleri. Sonuçlar Sentry'e loglanır.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                stage4Results = Stage4SelfTest.runAll()
            } label: {
                Label("Stage 4 self-test çalıştır", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            ForEach(stage4Results) { resultRow($0) }
            summary(stage4Results)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 3

    private var stage3Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 3 — Camera / OCR / Liveness").font(.headline)
            NavigationLink { MRZScanTestView() } label: { Label("MRZ Tarama Testi", systemImage: "text.viewfinder") }.buttonStyle(.bordered)
            NavigationLink { QRScanTestView() } label: { Label("QR Tarama Testi", systemImage: "qrcode.viewfinder") }.buttonStyle(.bordered)
            NavigationLink { LivenessTestView() } label: { Label("Liveness Testi", systemImage: "face.smiling") }.buttonStyle(.bordered)
            Button { stage3Results = Stage3SelfTest.runAll() } label: { Label("Stage 3 self-test çalıştır", systemImage: "checklist") }.buttonStyle(.bordered)
            ForEach(stage3Results) { resultRow($0) }
            summary(stage3Results)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 2

    private var stage2Section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 2 — NFC").font(.headline)
            NavigationLink { NFCTestView() } label: { Label("NFC Çip Okuma Testi", systemImage: "wave.3.right") }.buttonStyle(.bordered)
            Button { stage2Results = Stage2SelfTest.runAll() } label: { Label("Stage 2 self-test çalıştır", systemImage: "checklist") }.buttonStyle(.bordered)
            ForEach(stage2Results) { resultRow($0) }
            summary(stage2Results)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Aşama 1

    private var selfTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Stage 1 Self-Test").font(.headline)
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
            summary(selfTestResults)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func summary(_ results: [SelfTestResult]) -> some View {
        if !results.isEmpty {
            let passed = results.filter { $0.passed }.count
            Text("\(passed)/\(results.count) passed")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(passed == results.count ? .green : .red)
        }
    }

    private func resultRow(_ result: SelfTestResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.passed ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.footnote.weight(.medium))
                Text(result.detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
#endif
