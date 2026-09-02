import Foundation

/// Kayıt akışı orkestrasyonu — Android `MainActivity` + `MainViewModel.finalizeRegistration`/
/// `completeDemoRegistration` portu. Adımlar: Hazırlık → MRZ → NFC → Liveness → İşlem → Başarı.
@MainActor
final class RegisterViewModel: ObservableObject {

    enum Step: Equatable {
        case preparation
        case mrz
        case nfc
        case biometricConsent   // KVKK biyometrik rıza — liveness'tan hemen önce (Android paritesi)
        case liveness
        case processing
        case success
        /// `offersSettings`: kullanıcı bunu cihaz Ayarlar'ından düzeltebilir mi — hata
        /// ekranı buna göre "Ayarları Aç" butonu gösterir. Adımın içinde taşınıyor ki
        /// ayrı bir @Published ile desenkron olamasın.
        case failed(title: String, message: String, offersSettings: Bool)
    }

    @Published var step: Step = .preparation { didSet { trackFurthestStep() } }

    /// Bu denemede ulaşılan EN İLERİ adım. Kullanıcı liveness'ı iptal edip MRZ'ye düşerse anlık
    /// adım geri sarılır ve "nerede bıraktı" sorusunu yanlış yanıtlar; vazgeçme noktası ulaştığı
    /// en ileri noktadır.
    private(set) var furthestFlowStep: FlowFeedbackPrompt.FlowStep?

    private func trackFurthestStep() {
        let reached: FlowFeedbackPrompt.FlowStep?
        switch step {
        case .mrz:                         reached = .mrz
        case .nfc:                         reached = .nfc
        case .biometricConsent, .liveness: reached = .liveness
        case .processing:                  reached = .submit
        default:                           reached = nil
        }
        guard let reached else { return }
        if furthestFlowStep == nil || reached.order > furthestFlowStep!.order {
            furthestFlowStep = reached
        }
    }
    @Published var kvkkAccepted = false
    /// "Başla" basıldıktan sonra handshake biter ekran değişene kadar true — çift basmayı + ikinci
    /// handshake'i engeller, butonu spinner durumuna geçirir.
    @Published var isStarting = false
    @Published var nfcStatus: String = L.t("nfc_searching")
    /// Kart kaydı/bağlantı koparsa: akışı kırmadan NFC adımında "tekrar dene" mesajı (Android UX).
    @Published var nfcRetryMessage: String? = nil

    private var nfcAttempt = 0   // sessiz oto-tekrar sayacı (en fazla 3)
    /// Bozuk çip imzası yüzünden kaç kez yeniden okutma istendi (bkz. ChipSignatureCheck).
    private var chipRetry = 0
    /// Kaç kez yeniden okutma istenir. Bunlar bittiğinde akış SUNUCUYA devam eder — istemci
    /// kontrolü yapısal bir ipucudur ve kullanıcıyı kilitlememeli (gerekçe aşağıda).
    static let maxChipSignatureRetries = 3

    let isDemo: Bool

    private var userPubKey: String?
    private var session: HandshakeService.Session?
    private var mrz: MRZParser.Result?
    private(set) var scanned: ScannedPassport?
    private var selfieData: Data?
    /// Başarısız denemeden kalan kare — yalnız teşhis için, yalnız cihazda.
    private var diagnosticPhotoData: Data?

    /// Çip fotoğrafının hizalanmış 112×112 kırpımı ve son canlılık denemesinin skaler ölçüleri.
    /// İkisi de YALNIZ geri bildirim kutusuna taşınır: kırpım AYRI bir rıza anahtarına, ölçüler ise
    /// e-postanın gövdesine. Kayıt payload'ına GİRMEZLER.
    private(set) var chipAlignedPhoto: Data?
    private(set) var livenessDiagnostics: String?

    /// Bu denemenin huni anahtarı — geri bildirim e-postasına konur (bkz. FlowTelemetry.startFlow).
    private(set) var flowId: String?

    /// Handshake nonce'u — huni olaylarının geçerlilik anahtarı. Canlılık ekranı hareket
    /// olaylarını koşu SIRASINDA gönderdiği için bu değere ihtiyacı var.
    var flowNonce: String? { session?.nonce }
    /// Bu akışta canlılık testi bir kez bile düştü mü. Geri bildirim kutusunun metnini seçer:
    /// hatayla karşılaşmış birine "neden yarıda bıraktınız?" demek yanlış soru.
    private(set) var livenessDidFail = false
    private var antiSpoofCropData: Data?
    private var registrationNonce: String?

    var challenges: [Int] { session?.challenges ?? [] }

    /// Huni telemetrisi — yalnız GERÇEK kayıt akışı sayılır; demo istatistiği kirletmemeli.
    private func track(_ step: FlowTelemetry.Step) {
        guard !isDemo, let nonce = session?.nonce else { return }
        Task { await FlowTelemetry.shared.reached(step, nonce: nonce) }
    }
    var chipPhoto: Data? { scanned?.faceImage }
    /// MRZ'den tespit edilen belge tipi ("ID" | "PASSPORT") — NFC talimat metnini belirler (Android paritesi).
    var documentType: String { mrz?.documentType ?? "ID" }

    init(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - Akış başlangıcı

    /// "Başla" → user key + (gerçekte) handshake; demo'da doğrudan işleme.
    func begin() {
        guard kvkkAccepted, !isStarting else { return }
        isStarting = true
        AppPrefs.kvkkConsentAccepted = true
        Task {
            // Hangi yoldan çıkarsak çıkalım (başarı/hata/erken return) butonu serbest bırak.
            defer { isStarting = false }
            // Cihaz kilidi (biyometri/passcode) yoksa `.userPresence` anahtarı ÜRETİLEMEZ ve
            // ensureUserKey errSecAuthFailed ile düşer. Önden kontrol edip NE YAPILACAĞINI söyleyen
            // net mesaj göster — aksi halde kullanıcı jenerik "güvenlik hatası" görüyordu.
            guard BiometricGate.isDeviceLockAvailable() else {
                // Tek düzeltilebilir hata bu: kullanıcı Ayarlar'dan kilit tanımlayıp dönebilir.
                fail(title: L.t("biometric_required_title"),
                     message: L.t("biometric_device_lock_required_message"),
                     error: nil,
                     offersSettings: true)
                return
            }
            do {
                userPubKey = try KeychainKeyStore.ensureUserKey()
            } catch {
                fail(title: L.t("security_error_title"), message: L.t("error_demo_key_not_ready"), error: error)
                return
            }
            livenessDidFail = false
            if isDemo {
                // Demo: handshake yok; gerçek akışla aynı ekranlardan geçer (Android demo paritesi).
                // MRZ(~2s, sahte) → NFC(~2s) → Liveness(demo, oto-jest) → İşlem → demoRegister.
                step = .mrz
            } else {
                do {
                    flowId = await FlowTelemetry.shared.startFlow()
                    session = try await HandshakeService.shared.performRegisterHandshake()
                    track(.handshake)
                    step = .mrz
                } catch {
                    // Ham `localizedDescription` GÖSTERİLMEZ: sistem metni teknik ve cihaz
                    // diline bağlı; 5xx durumunda "Bağlantı Hatası" başlığı da yanlış olurdu.
                    fail(title: UserFacingError.title(for: error),
                         message: UserFacingError.message(for: error),
                         error: error)
                }
            }
        }
    }

    // MARK: - Geri

    /// Bir adım geri. Android `btnStepperBack` paritesi: NFC → MRZ, MRZ → Hazırlık.
    ///
    /// Geri gidilecek adım yoksa `false` döner ve çağıran akıştan çıkar — Hazırlık'tan
    /// geri gitmek zaten cüzdana dönmek demek.
    ///
    /// Neden ayrı bir fonksiyon: geri tuşu eskiden hangi adımda olursa olsun akıştan
    /// TAMAMEN çıkıyordu. Kullanıcı NFC adımında kartı okutamayıp bir ekran geri dönmek
    /// istediğinde kaydı bastan basliyordu — el sıkışma dahil.
    func stepBack() -> Bool {
        switch step {
        case .nfc:
            // Sayaçlar sıfırlanmazsa geri dönüp tekrar gelen kullanıcı, önceki denemelerin
            // bütçesini tüketmiş halde başlar ve daha erken hata ekranına düşer.
            nfcAttempt = 0
            chipRetry = 0
            nfcRetryMessage = nil
            nfcStatus = L.t("nfc_searching")
            step = .mrz
            return true
        case .mrz:
            mrz = nil   // Hazırlığa dönüldü; MRZ yeniden okutulacak.
            step = .preparation
            return true
        default:
            return false
        }
    }

    // MARK: - MRZ

    func onMrz(_ result: MRZParser.Result) {
        mrz = result
        track(.mrz)
        step = .nfc
    }

    // MARK: - NFC

    /// NFC giriş noktası (MRZ→NFC veya manuel "Yeniden Dene"): deneme sayacını sıfırlar.
    func startNfc() {
        nfcAttempt = 0
        nfcRetryMessage = nil
        runNfcAttempt()
    }

    /// Manuel "Yeniden Dene" (3 sessiz deneme de başarısız olduktan sonraki hata ekranından).
    func retryNfc() {
        startNfc()
    }

    private func runNfcAttempt() {
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
                    documentType: mrz.documentType,
                    handshakeNonce: session.nonce
                )
                nfcAttempt = 0

                // Hızlı-başarısızlık: desteklenmeyen belgeyi (TR dışı / pasaport / JPEG2000 DG2 /
                // AA-desteksiz) BURADA durdur. Aksi halde kullanıcı tüm liveness'i boşa yapıp en
                // sonda enclave reddine çarpar; üstelik fotoğraf çözülemediğinde yüz eşleştirme
                // sessizce atlanır (güvenlik boşluğu). PII yok — yalnız verdict + ülke/belge kodu.
                let verdict = DocumentSupport.evaluate(
                    issuingState: result.issuingState, documentCode: result.documentType,
                    faceImage: result.faceImage, dg15: result.dg15, activeSig: result.activeAuthSignature,
                    chipSignatureReadable: ChipSignatureCheck.isReadable(
                        dg15: result.dg15, signature: result.activeAuthSignature))

                // Bozuk çip okuması bir BELGE sorunu değil: kullanıcıya "desteklenmiyor" demek
                // yanlış olur, kartı yeniden okutması yeter. Akış NFC adımında kalır — aksi halde
                // ~90 saniyelik canlılık testini boşuna yapıp en sonda sunucudan reddediliyordu.
                // Üst üste birkaç denemede düzelmezse KARARI SUNUCUYA BIRAKIRIZ: istemci kontrolü
                // yapısal bir ipucudur, kullanıcıyı kilitlememeli.
                if verdict == .chipSignatureUnreadable, chipRetry < Self.maxChipSignatureRetries {
                    chipRetry += 1
                    Log.warning("Çip imzası bozuk okundu (deneme \(chipRetry)) — yeniden okutma isteniyor",
                                category: .nfc)
                    // İlk uyarı kısa; ısrar ederse fiziksel sebepleri söyle (kılıf, arkadaki kartlar,
                    // hareket). Bozuk AA okumasının pratikteki sebepleri bunlar.
                    nfcRetryMessage = chipRetry == 1
                        ? L.t("doc_chip_unreadable") : L.t("doc_chip_unreadable_retry")
                    step = .nfc
                    return
                }

                if verdict != .supported, verdict != .chipSignatureUnreadable {
                    Log.warning("Desteklenmeyen belge: \(verdict) ihraçÜlke=\(result.issuingState) belgeKodu=\(result.documentType)", category: .nfc)
                    let message: String
                    switch verdict {
                    case .unsupportedCountry: message = L.t("doc_unsupported_country")
                    case .unsupportedDocType: message = L.t("doc_unsupported_doc_type")
                    case .unsupportedImage:   message = L.t("doc_unsupported_image")
                    case .noActiveAuth:       message = L.t("doc_unsupported_no_aa")
                    default:                  message = L.t("doc_unsupported_generic")
                    }
                    scanned = nil  // güvenlik: desteklenmeyen veriyle akışa devam etme
                    reportNfcFailure("doc_unsupported")
                    fail(title: L.t("doc_unsupported_title"), message: message, error: nil)
                    return
                }

                scanned = result
                track(.nfc)
                if challenges.isEmpty {
                    step = .processing
                    await finalizeReal()
                } else {
                    step = .biometricConsent   // rıza → liveness
                }
            } catch let e as NFCReadError {
                switch e {
                case .cancelled:
                    Log.info("NFC iptal edildi", category: .nfc)
                    step = .mrz
                case .notAvailable, .invalidInput:
                    reportNfcFailure(Self.nfcReason(for: e))
                    fail(title: L.t("nfc_not_found_title"), message: e.errorDescription ?? L.t("nfc_read_error"), error: e)
                default:
                    await retryOrFail(reason: "\(e)", nfcReason: Self.nfcReason(for: e))
                }
            } catch {
                await retryOrFail(reason: error.localizedDescription, nfcReason: "read_error")
            }
        }
    }

    /// Bağlantı koparsa (kart kaydı/timeout/unknown): UYARI ÇIKARMADAN 1s bekleyip sessizce tekrar
    /// dener — en fazla 3 kez. Üçü de başarısızsa hata ekranı + "Yeniden Dene" (Android UX).
    private func retryOrFail(reason: String, nfcReason: String) async {
        if nfcAttempt < 3 {
            nfcAttempt += 1
            Log.warning("NFC denemesi başarısız (\(reason)) → 1s sonra sessiz tekrar #\(nfcAttempt)/3", category: .nfc)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            runNfcAttempt()
        } else {
            Log.warning("NFC 3 sessiz deneme başarısız → hata ekranı (\(reason))", category: .nfc)
            nfcAttempt = 0
            // Huni sebebi BURADA düşer, sessiz tekrarlarda değil: üç kez yeniden denenip düzelen
            // okuma bir hata değil, gürültüdür.
            reportNfcFailure(nfcReason)
            nfcRetryMessage = L.t("nfc_read_error")
        }
    }

    /// NFC hatasını huninin sabit kümesine indirger.
    ///
    /// iOS'ta ayrım BEDAVA: `NFCReadError` zaten tipli (Android'de jmrtd her şey için
    /// `CardServiceException` attığı için okuyucuyu sarmalamak gerekti). `aa_failed` iOS'ta HİÇ
    /// üretilmez — NFCPassportReader Active Authentication hatasını ayrı bir vaka olarak
    /// bildirmiyor, `.unknown` içinde eriyor. Küme ortak, doluluğu platforma göre değişir.
    private static func nfcReason(for error: NFCReadError) -> String {
        switch error {
        case .authenticationFailed:       return "auth_failed"
        case .connectionLost, .timeout:   return "tag_lost"
        default:                          return "read_error"
        }
    }

    /// Demo akışı huniyi kirletmez (track ile aynı kural).
    private func reportNfcFailure(_ reason: String) {
        guard !isDemo, let nonce = session?.nonce else { return }
        Task { await FlowTelemetry.shared.nfcFailed(reason: reason, nonce: nonce) }
    }

    // MARK: - Liveness

    func onLiveness(selfie: Data, antiSpoofCrop: Data?, score: Float, diagnostics: LivenessDiagnostics?) {
        selfieData = selfie
        antiSpoofCropData = antiSpoofCrop
        // Başarıda da saklanır: sunucudaki anti-spoof reddi bu adımdan SONRA geliyor, yani
        // "canlılık geçti ama kayıt düştü" vakasında elimizdeki tek kare ölçüsü bu.
        captureDiagnostics(diagnostics)
        track(.liveness)
        step = .processing
        Task {
            if isDemo { await runDemo() } else { await finalizeReal() }
        }
    }

    /// Canlılık ekranından çıkış: başarısızlık diyaloğundaki "Vazgeç", koşu sırasındaki geri oku
    /// ve kamera izni ekranındaki "Kapat".
    ///
    /// Akıştan TAMAMEN çıkılır; adım MRZ'ye alınmaz. Eskiden kullanıcıyı, çıkmak istediği akışın
    /// bir önceki adımında — kart tarama ekranında — bırakıyorduk: ne huniye bir şey söylüyorduk
    /// ne de kullanıcıya "bir sorun mu yaşadınız?" diye soruyorduk. Android bunu baştan beri
    /// böyle yapıyordu; parite iOS'ta eksikti.
    ///
    /// Yeniden denemek için MRZ'ye dönmeye gerek yok: diyalogdaki "Tekrar Dene" canlılığı
    /// yerinde yeniden başlatıyor, kart ve çip okuması korunuyor.
    func onLivenessCancel() {
        Log.info("Canlılık ekranından vazgeçildi → akıştan çıkılıyor", category: .liveness)
        guard !isDemo, let nonce = session?.nonce else { return }
        // Huni "canlılıkta kaç kişi pes etti"yi ancak buradan öğrenir. Gerçek bir hata zaten
        // düştüyse `livenessFailed` bir kez gönderiliyor ve o daha bilgilendirici olan sebeptir.
        Task { await FlowTelemetry.shared.livenessFailed(reason: "cancelled", nonce: nonce) }
    }

    /// Canlılık testi başarısız bitti. Kullanıcı "Tekrar Dene" diyebilir — akış BURADA kırılmaz,
    /// yalnız huniye "canlılık adımını neden kaybettik" bilgisi düşer (aynı sebep akış başına bir kez).
    func onLivenessFailed(_ reason: LivenessViewModel.FailureReason, photo: Data?,
                          diagnostics: LivenessDiagnostics?) {
        guard !isDemo else { return }
        livenessDidFail = true
        captureDiagnostics(diagnostics)
        // Reddedilen kareyi CİHAZDA saklıyoruz. Geri bildirim kutusundaki "fotoğrafı ekle"
        // kutucuğu ancak elde kare varsa çıkıyordu ve kare yalnız BAŞARIDA doldurulduğu için
        // tam da ihtiyaç duyduğumuz durumda — eşleşme düştüğünde — kutucuk hiç görünmüyordu.
        // Kare buradan sunucuya GİTMEZ; yalnız kullanıcı açıkça işaretlerse e-postaya ek olur.
        if let photo { diagnosticPhotoData = photo }
        guard let nonce = session?.nonce else { return }
        let score = diagnostics?.matchScorePercent
        Task { await FlowTelemetry.shared.livenessFailed(reason: reason.rawValue, nonce: nonce, score: score) }
    }

    /// Demo: NFC ekranı ~2s sonra biyometrik rızaya geçer (Android `demoProceedAfterNfc`).
    func demoAfterNfc() {
        guard isDemo else { return }
        step = .biometricConsent
    }

    /// Biyometrik rıza onaylandı → liveness (gerçek + demo ortak).
    /// Adım koruması: demo oto-onayı geç tetiklenirse (kullanıcı zaten ilerlemişse) yok sayılır.
    func approveBiometricConsent() {
        guard step == .biometricConsent else { return }
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
            if let antiSpoofCropData { payload.antiSpoofCrop = antiSpoofCropData.base64EncodedString() }
            // iOS App Attest (Aşama 6) relay'de el sıkışmada doğrulanır; register enclave'e proxy'lenir
            // ve el sıkışma nonce'una bağlıdır → şifreli IntegrityToken iOS'ta BOŞ bırakılır (Android'de
            // bu alan Play Integrity taşır). Bkz. AppAttestService + sunucu ClientAttestationGate.

            let json = try encodeToString(payload)
            let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(json)
            let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: session.enclavePubKey)
            let req = RegistrationRequest(encryptedKey: encKey, aesBlob: aesBlob, countryIsoCode: scanned.issuingState)

            track(.submit)
            let resp = try await VerifyAPI.shared.register(req)
            registrationNonce = resp.registrationNonce
            try await processTicketResponse(resp)
            track(.success)
            step = .success
        } catch {
            if failIfCancelled(error) { return }
            // 5xx'te akış başlığı ("Kayıt Başarısız") kullanıcıya kendi yaptığı bir şeyin bozulduğunu
            // düşündürüyor; sorun bizdeyken bunu söyle (Android `error_server_unavailable_title`).
            // Uçak modundayken de "sunucu hatası" DENMEZ: bu dal eskiden ham sistem metnini ya da
            // `error_registration_server`'i basiyordu, yani kullanicinin kendi baglantisizligini
            // bizim arizamiz gibi gosteriyordu (Android `ServerErrorMessages` paritesi).
            fail(title: UserFacingError.title(for: error, internalFallbackKey: "registration_failed_status"),
                 message: UserFacingError.message(for: error, internalFallbackKey: "error_registration_server"),
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
            if failIfCancelled(error) { return }
            fail(title: UserFacingError.title(for: error, internalFallbackKey: "error_demo_registration_title"),
                 message: UserFacingError.message(for: error, internalFallbackKey: "error_demo_server"),
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

    /// Hata anındaki adım — geri bildirim kutusunun konusunu ön-doldurmak için.
    private(set) var failedAtStep: FlowFeedbackPrompt.FlowStep?

    /// Başarısız denemedeki selfie — kullanıcı geri bildirim formunda AÇIKÇA onaylarsa desteğe
    /// gönderilir. Otomatik hiçbir yere iletilmez; onay kutusu kapalı gelir.
    var diagnosticSelfie: Data? { selfieData ?? diagnosticPhotoData }

    /// Demo akışı gerçek bir deneme değil — teşhis paketi de toplanmaz (huni gatelemesiyle aynı kural).
    private func captureDiagnostics(_ diagnostics: LivenessDiagnostics?) {
        guard !isDemo, let diagnostics else { return }
        if let png = diagnostics.chipAlignedPNG { chipAlignedPhoto = png }
        if !diagnostics.summary.isEmpty { livenessDiagnostics = diagnostics.summary }
    }

    /// Biyometrik prompt iptali (kullanıcı vazgeçti / ekran kilitlendi) "başarısızlık" DEĞİLDİR:
    /// nötr başlık + nötr metin gösterilir ve `Log.failure` seviyesi `.info`ya düşer → Sentry'ye
    /// event GİTMEZ. Android'de bunun karşılığı akışın sessizce iptal edilip toast gösterilmesidir.
    /// - Returns: iptal yakalandıysa `true` (çağıran genel hata yolunu atlar).
    private func failIfCancelled(_ error: Error) -> Bool {
        guard BiometricErrorClass.isCancellation(error) else { return false }
        fail(title: L.t("biometric_cancelled_title"), message: L.t("biometric_cancelled_message"), error: error)
        return true
    }

    private func fail(title: String, message: String, error: Error?, offersSettings: Bool = false) {
        switch step {
        case .mrz:                         failedAtStep = .mrz
        case .nfc:                         failedAtStep = .nfc
        case .biometricConsent, .liveness: failedAtStep = .liveness
        default:                           failedAtStep = .submit
        }
        let text = error != nil ? "Register başarısız: \(title)" : "Register başarısız: \(title) — \(message)"
        if offersSettings {
            // Kullanıcının Ayarlar'dan düzeltebildiği her durum tanımı gereği bizim arızamız değil,
            // beklenen bir çevre durumudur → info (Sentry'ye event değil, breadcrumb). Android aynı
            // sınıflandırmayı Availability.NO_DEVICE_LOCK üzerinden yapıyor.
            // DİKKAT: ileride GERÇEK bir arızaya "Ayarları Aç" butonu eklenirse bu bağ yeniden
            // düşünülmeli — o hata sessizleşmemeli.
            Log.info(text, category: .flow)
        } else {
            // Seviye hatanın türünden gelir (NFC/ağ/biyometrik iptal = warning/info, gerçek arıza = error).
            Log.failure(text, error: error, category: .flow)
        }
        step = .failed(title: title, message: message, offersSettings: offersSettings)
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
