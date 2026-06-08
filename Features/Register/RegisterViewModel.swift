import Foundation

/// Kayıt akışı orkestrasyonu — Android `MainActivity` + `MainViewModel.finalizeRegistration`/
/// `completeDemoRegistration` portu. Adımlar: Hazırlık → MRZ → NFC → Liveness → İşlem → Başarı.
@MainActor
final class RegisterViewModel: ObservableObject {

    enum Step: Equatable {
        case preparation
        case mrz
        case nfc
        case liveness
        case processing
        case success
        case failed(title: String, message: String)
    }

    @Published var step: Step = .preparation
    @Published var kvkkAccepted = false
    @Published var nfcStatus: String = L.t("nfc_searching")

    let isDemo: Bool

    private var userPubKey: String?
    private var session: HandshakeService.Session?
    private var mrz: MRZParser.Result?
    private(set) var scanned: ScannedPassport?
    private var selfieData: Data?
    private var registrationNonce: String?

    var challenges: [Int] { session?.challenges ?? [] }
    var chipPhoto: Data? { scanned?.faceImage }

    init(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - Akış başlangıcı

    /// "Başla" → user key + (gerçekte) handshake; demo'da doğrudan işleme.
    func begin() {
        guard kvkkAccepted else { return }
        AppPrefs.kvkkConsentAccepted = true
        Task {
            do {
                userPubKey = try KeychainKeyStore.ensureUserKey()
            } catch {
                fail(title: L.t("security_error_title"), message: L.t("error_demo_key_not_ready"), error: error)
                return
            }
            if isDemo {
                // Demo: handshake yok; gerçek akışla aynı ekranlardan geçer (Android demo paritesi).
                // MRZ(~2s, sahte) → NFC(~2s) → Liveness(demo, oto-jest) → İşlem → demoRegister.
                step = .mrz
            } else {
                do {
                    session = try await HandshakeService.shared.performRegisterHandshake()
                    step = .mrz
                } catch {
                    fail(title: L.t("connection_error_title"), message: error.localizedDescription, error: error)
                }
            }
        }
    }

    // MARK: - MRZ

    func onMrz(_ result: MRZParser.Result) {
        mrz = result
        step = .nfc
    }

    // MARK: - NFC

    func startNfc() {
        guard let mrz, let session else {
            fail(title: L.t("error_system_title"), message: L.t("err_passport_data_lost"), error: nil)
            return
        }
        Task {
            do {
                nfcStatus = L.t("nfc_reading")
                let reader = PassportNFCReader()
                let result = try await reader.read(
                    documentNumber: mrz.documentNumber,
                    dateOfBirth: mrz.dateOfBirth,
                    dateOfExpiry: mrz.dateOfExpiry,
                    handshakeNonce: session.nonce
                )
                scanned = result
                if challenges.isEmpty {
                    step = .processing
                    await finalizeReal()
                } else {
                    step = .liveness
                }
            } catch let e as NFCReadError {
                if case .cancelled = e {
                    // İptal → MRZ'ye geri dön (kullanıcı tekrar deneyebilir).
                    Log.info("NFC iptal edildi", category: .nfc)
                    step = .mrz
                } else {
                    fail(title: L.t("nfc_connection_failed_status"),
                         message: e.errorDescription ?? L.t("nfc_read_error"),
                         error: e)
                }
            } catch {
                fail(title: L.t("nfc_connection_failed_status"),
                     message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                     error: error)
            }
        }
    }

    // MARK: - Liveness

    func onLiveness(selfie: Data, score: Float) {
        selfieData = selfie
        step = .processing
        Task {
            if isDemo { await runDemo() } else { await finalizeReal() }
        }
    }

    func onLivenessCancel() {
        step = .mrz
    }

    /// Demo: NFC ekranı ~2s sonra liveness'a geçer (Android `demoProceedAfterNfc`).
    func demoAdvanceToLiveness() {
        guard isDemo else { return }
        step = .liveness
    }

    // MARK: - Gerçek kayıt finalize

    private func finalizeReal() async {
        guard let scanned, let session, let userPubKey else {
            fail(title: L.t("error_system_title"), message: L.t("err_passport_data_lost"), error: nil)
            return
        }
        do {
            var payload = scanned.makeSecurePayload(
                userPubKey: userPubKey,
                nonce: session.nonce,
                timestamp: session.timestamp,
                nonceSignature: session.nonceSignature
            )
            if let selfieData { payload.userSelfie = selfieData.base64EncodedString() }
            // integrityToken = "" (Aşama 4 dev-skip)

            let json = try encodeToString(payload)
            let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(json)
            let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: session.enclavePubKey)
            let req = RegistrationRequest(encryptedKey: encKey, aesBlob: aesBlob, countryIsoCode: scanned.issuingState)

            let resp = try await VerifyAPI.shared.register(req)
            registrationNonce = resp.registrationNonce
            try await processTicketResponse(resp)
            step = .success
        } catch {
            fail(title: L.t("registration_failed_status"),
                 message: (error as? LocalizedError)?.errorDescription ?? L.t("error_registration_server"),
                 error: error)
        }
    }

    // MARK: - Demo kayıt

    private func runDemo() async {
        guard let userPubKey else {
            fail(title: L.t("error_demo_registration_title"), message: L.t("error_demo_key_not_ready"), error: nil)
            return
        }
        do {
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            let resp = try await VerifyAPI.shared.demoRegister(DemoRegisterRequest(userPubKey: userPubKey, appVersion: appVersion))
            registrationNonce = resp.registrationNonce
            try await processTicketResponse(resp)
            step = .success
        } catch {
            fail(title: L.t("error_demo_registration_title"),
                 message: (error as? LocalizedError)?.errorDescription ?? L.t("error_demo_server"),
                 error: error)
        }
    }

    // MARK: - Ticket işleme (ortak)

    private func processTicketResponse(_ resp: EncryptedTicketResponse) async throws {
        guard let userPubKey else { throw RegistrationError.missingUserKey }
        // encrypted_ticket = stringlenmiş HybridContent JSON.
        guard let htData = resp.encryptedTicket.data(using: .utf8),
              let hybrid = try? JSONDecoder().decode(HybridContent.self, from: htData) else {
            throw RegistrationError.badTicketEnvelope
        }
        // Biyometrik decrypt (user key, OAEP-SHA1) → AES key.
        let aesKey = try await KeychainKeyStore.decryptWithUserKey(hybrid.encKey, reason: L.t("biometric_subtitle_decrypt"))
        let plainJson = try CryptoUtils.aesDecrypt(blobBase64: hybrid.blob, keyBase64: aesKey)

        let unified = try JSONDecoder().decode(UnifiedRegistrationPayload.self, from: Data(plainJson.utf8))
        // RAW ticket sub-JSON'ı çıkar (typed round-trip ile alan kaybı yok).
        let rawTicketJson = try extractRawTicket(from: plainJson)

        try TicketStore.save(signedTicketJson: rawTicketJson, pubKey: userPubKey)
        SecureStore.saveIds(personId: unified.personId, cardId: unified.cardId)
        AppPrefs.expiryDate = unified.ticket.payload.gecerlilikTarihi

        HistoryRepository.shared.insert(
            title: L.t("history_card_added_title"),
            description: L.t("history_tckn_prefix") + Masker.mask(unified.ticket.payload.tckn),
            status: 1,
            actionType: .registration,
            nonce: registrationNonce ?? UUID().uuidString,
            personId: unified.personId,
            cardId: unified.cardId
        )
        Log.info("Kayıt başarılı (cardId set)", category: .flow)
    }

    private func extractRawTicket(from unifiedJson: String) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: Data(unifiedJson.utf8)) as? [String: Any],
              let ticketObj = obj["ticket"] else {
            throw RegistrationError.badTicketEnvelope
        }
        let data = try JSONSerialization.data(withJSONObject: ticketObj, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func fail(title: String, message: String, error: Error?) {
        if let error { Log.error("Register başarısız: \(title)", error: error, category: .flow) }
        else { Log.error("Register başarısız: \(title) — \(message)", category: .flow) }
        step = .failed(title: title, message: message)
    }
}

enum RegistrationError: Error, LocalizedError {
    case missingUserKey
    case badTicketEnvelope

    var errorDescription: String? {
        switch self {
        case .missingUserKey:    return L.t("error_demo_key_not_ready")
        case .badTicketEnvelope: return L.t("error_ticket_not_found")
        }
    }
}
