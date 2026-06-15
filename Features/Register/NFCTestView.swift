import SwiftUI

/// Aşama 2 cihaz doğrulama ekranı — fiziksel kart + gerçek iPhone ile çip okumayı test eder.
/// Dev/TestFlight Internal'da görünür (ContentView dev env kapısı). Aşama 4'te gerçek Register
/// akışıyla değişecek.
///
/// PII güvenliği: belge no / isim Sentry'e GİTMEZ; ekranda yalnızca PII olmayan özet gösterilir
/// (okunan veri grupları + boyutları, AA durumu, challenge eşleşmesi, belge tipi/uyruk).
/// Dil: `feedback_never_share_identity_wording` — "Kart okundu / Çip doğrulandı" (yasak ifadeler yok).
struct NFCTestView: View {
    // Geliştirici test kartı için ön-doldurulmuş MRZ (yalnızca bu dev test ekranı; gerçek
    // Register akışı Aşama 4'te kullanıcı girişiyle çalışacak).
    // Default'lar BOŞ — gerçek kart verisi release binary'de/public repo'da olmasın (Y-13).
    @State private var docNo = ""
    @State private var dob = ""
    @State private var doe = ""
    @State private var scanning = false
    @State private var summary: [String] = []
    @State private var errorText: String?

    private let reader = PassportNFCReader()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Kimlik kartınızın arka yüzündeki MRZ alanından Belge No, Doğum Tarihi ve Son Geçerlilik bilgilerini girin, ardından kartı iPhone'un üst arkasına tutun.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                field("Belge No", text: $docNo)
                field("Doğum Tarihi (GG.AA.YYYY)", text: $dob)
                field("Son Geçerlilik (GG.AA.YYYY)", text: $doe)

                Button {
                    Task { await scan() }
                } label: {
                    Label(scanning ? "Taranıyor…" : "Çipi Tara", systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanning || docNo.isEmpty || dob.isEmpty || doe.isEmpty)

                if !NFCReadError.readingAvailable {
                    Label("Bu cihaz NFC okumayı desteklemiyor.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Çip doğrulandı", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        ForEach(summary, id: \.self) { line in
                            Text(line).font(.footnote.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle("Aşama 2 — NFC")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        }
    }

    private func scan() async {
        scanning = true
        errorText = nil
        summary = []
        defer { scanning = false }

        do {
            // Handshake yalnızca AA challenge'ı türetmek için nonce sağlar. Bu aşamada GERÇEK
            // kart verisi sunucuya GÖNDERİLMEZ (register/login = Aşama 4).
            let hs = try await VerifyAPI.shared.handshake()
            let passport = try await reader.read(
                documentNumber: docNo,
                dateOfBirth: dob,
                dateOfExpiry: doe,
                handshakeNonce: hs.nonce
            )

            let expected = Array(CryptoUtils.sha256Bytes(hs.nonce).prefix(8))
            let challengeMatch = Array(passport.aaChallenge) == expected

            summary = [
                "DG1: \(passport.dg1.count) bayt",
                "DG2 (yüz): \(passport.faceImage?.count ?? 0) bayt",
                "DG15: \(passport.dg15?.count ?? 0) bayt",
                "SOD: \(passport.sod.count) bayt",
                "AA destekli: \(passport.activeAuthSupported ? "evet" : "hayır")",
                "AA imza: \(passport.activeAuthSignature.count) bayt",
                "AA challenge eşleşti: \(challengeMatch ? "✓" : "✗")",
                "Belge tipi: \(passport.documentType)",
                "Uyruk: \(passport.nationality) · Veren: \(passport.issuingState)",
            ]
            Log.info(
                "NFCTestView OK: AAmatch=\(challengeMatch) AAsupported=\(passport.activeAuthSupported) " +
                "docType=\(passport.documentType) nat=\(passport.nationality)",
                category: .nfc
            )
        } catch let e as NFCReadError {
            errorText = e.errorDescription
            Log.warning("NFCTestView NFCReadError: \(e)", category: .nfc)
        } catch {
            errorText = "Beklenmeyen hata: \(error.localizedDescription)"
            Log.error("NFCTestView beklenmeyen hata", error: error, category: .nfc)
        }
    }
}

#Preview {
    NavigationStack { NFCTestView() }
}
