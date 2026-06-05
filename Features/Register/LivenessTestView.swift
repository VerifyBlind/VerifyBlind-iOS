import SwiftUI

/// Aşama 3 dev test ekranı — liveness. Üç mod:
/// - **Çipsiz**: gerçek jest akışı (sol/sağ/blink/smile) + en iyi selfie yakalama + hizalama (%'siz).
/// - **Demo**: jest beklemeden her adım otomatik geçer (UI akışı doğrulaması).
/// - **Çip ile (NFC)**: önce çipten DG2 yüzü okunur → canlı % + best-match-frame (model gömülüyse).
///
/// Çip okuma Aşama 2 `PassportNFCReader`'ı yeniden kullanır (prefilled dev kart MRZ'si).
struct LivenessTestView: View {
    // Dev test kartı (NFCTestView ile aynı).
    @State private var docNo = "A36S661356"
    @State private var dob = "10.06.1981"
    @State private var doe = "04.07.2032"

    @State private var session: LivenessSession?
    @State private var lastSelfie: UIImage?
    @State private var lastScore: Float?
    @State private var statusText: String?
    @State private var readingChip = false

    private let reader = PassportNFCReader()
    private let challenges = [1, 2, 3, 4] // faceLeft, faceRight, blink, smile (VM ≥5'e tamamlar)

    struct LivenessSession: Identifiable {
        let id = UUID()
        let chip: Data?
        let isDemo: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Liveness akışını cihazda doğrular. Çipsiz mod jestleri + yakalama + hizalamayı; çip modu canlı % eşleşmesini test eder (model gömülüyse).")
                    .font(.footnote).foregroundStyle(.secondary)

                Button {
                    session = LivenessSession(chip: nil, isDemo: false)
                } label: {
                    Label("Çipsiz Liveness", systemImage: "face.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    session = LivenessSession(chip: nil, isDemo: true)
                } label: {
                    Label("Demo Liveness", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Divider()

                Text("Çip ile (canlı %)").font(.headline)
                field("Belge No", text: $docNo)
                field("Doğum Tarihi (GG.AA.YYYY)", text: $dob)
                field("Son Geçerlilik (GG.AA.YYYY)", text: $doe)

                Button {
                    Task { await readChipThenLiveness() }
                } label: {
                    Label(readingChip ? "Çip okunuyor…" : "Çip oku + Liveness", systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(readingChip || docNo.isEmpty || dob.isEmpty || doe.isEmpty)

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let lastSelfie {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Son liveness sonucu", systemImage: "checkmark.seal.fill")
                            .font(.headline).foregroundStyle(.green)
                        HStack {
                            Image(uiImage: lastSelfie)
                                .resizable().interpolation(.none)
                                .frame(width: 112, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text("Hizalanmış 112×112 selfie").font(.caption)
                                if let lastScore {
                                    Text("Eşleşme: %\(Int(lastScore * 100))")
                                        .font(.footnote.monospaced())
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Aşama 3 — Liveness")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $session) { cfg in
            LivenessView(
                viewModel: LivenessViewModel(challenges: challenges, chipPhotoData: cfg.chip, isDemo: cfg.isDemo),
                onSuccess: { jpeg, score in
                    lastSelfie = UIImage(data: jpeg)
                    lastScore = score
                    statusText = "Liveness başarılı (skor %\(Int(score * 100)))."
                    session = nil
                },
                onCancel: {
                    statusText = "Liveness iptal/başarısız."
                    session = nil
                }
            )
        }
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

    private func readChipThenLiveness() async {
        readingChip = true
        statusText = nil
        defer { readingChip = false }
        do {
            let hs = try await VerifyAPI.shared.handshake()
            let passport = try await reader.read(
                documentNumber: docNo,
                dateOfBirth: dob,
                dateOfExpiry: doe,
                handshakeNonce: hs.nonce
            )
            guard let face = passport.faceImage, !face.isEmpty else {
                statusText = "Çip yüz fotoğrafı (DG2) okunamadı."
                return
            }
            session = LivenessSession(chip: face, isDemo: false)
        } catch let e as NFCReadError {
            statusText = e.errorDescription
        } catch {
            statusText = "Çip okuma hatası: \(error.localizedDescription)"
        }
    }
}
