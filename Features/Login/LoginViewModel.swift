import Foundation

/// Login (QR nonce) akışı — Android `MainViewModel.fetchPartnerInfo` + `completeLogin` portu.
/// QR tara → partner bilgisi → consent → login-handshake → ticket'i nonce ile sar → POST login.
@MainActor
final class LoginViewModel: ObservableObject {

    enum Step: Equatable {
        case scanning
        case loadingPartner
        case consent
        case processing
        case success
        case rejected
        case failed(title: String, message: String)
    }

    @Published var step: Step = .scanning
    @Published var partnerInfo: PartnerInfoResponse?

    private var nonce: String = ""
    private var pkHash: String?

    // MARK: - QR

    func onQr(_ payload: String) {
        guard let parsed = QRPayloadParser.parse(payload) else {
            fail(title: L.t("invalid_request"), message: L.t("invalid_qr"), error: nil)
            return
        }
        nonce = parsed.nonce
        pkHash = parsed.pkHash
        step = .loadingPartner
        Task { await fetchPartner() }
    }

    private func fetchPartner() async {
        guard TicketStore.hasTicket else {
            fail(title: L.t("error_no_card_title"), message: L.t("error_no_card_message"), error: nil)
            return
        }
        do {
            let info = try await VerifyAPI.shared.partnerInfo(nonce: nonce)
            PartnerManager.save(PartnerItem(
                partnerId: info.partnerId, name: info.name, logoUrl: info.logoUrl,
                logoBase64: info.logoBase64, timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            partnerInfo = info
            step = .consent
        } catch {
            fail(title: L.t("error_partner_title"),
                 message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                 error: error)
        }
    }

    // MARK: - Consent

    func approve() {
        step = .processing
        Task { await completeLogin() }
    }

    func reject() {
        Task { await cancelPop() }
        step = .rejected
    }

    // MARK: - Login finalize

    private func completeLogin() async {
        do {
            let enclavePubKey = try await HandshakeService.shared.ensureLoginHandshake()
            // Biyometrik decrypt → saklı SignedTicket RAW JSON.
            let signedTicketJson = try await TicketStore.decryptSignedTicket(reason: L.t("biometric_subtitle_decrypt"))
            let wrapper = try LoginWrapperBuilder.build(signedTicketJson: signedTicketJson, nonce: nonce, pkHash: pkHash)

            let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(wrapper)
            let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: enclavePubKey)
            let hybrid = HybridContent(encKey: encKey, blob: aesBlob)
            let hybridJson = String(decoding: try JSONEncoder().encode(hybrid), as: UTF8.self)

            let req = LoginRequest(encrSignedTicket: hybridJson, nonce: nonce)
            _ = try await VerifyAPI.shared.login(req)

            recordHistory()
            step = .success
        } catch {
            fail(title: L.t("login_failed_title"),
                 message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                 error: error)
        }
    }

    private func recordHistory() {
        let partnerName = partnerInfo?.name
        let desc = partnerName != nil ? (L.t("history_partner_prefix") + partnerName!) : L.t("history_qr_login")
        HistoryRepository.shared.insert(
            title: L.t("history_identity_shared_title"),   // "Doğrulama Tamamlandı" — yasak kelime DEĞİL
            description: desc,
            status: 1,
            actionType: .sharedIdentity,
            nonce: nonce,
            personId: SecureStore.getPersonId() ?? "",
            cardId: SecureStore.getCardId() ?? "",
            partnerId: partnerInfo?.partnerId
        )
    }

    private func cancelPop() async {
        do { try await VerifyAPI.shared.cancelPop(PopCancelRequest(nonce: nonce)) }
        catch { Log.warning("cancelPop başarısız (yok sayıldı): \(error.localizedDescription)", category: .flow) }
    }

    private func fail(title: String, message: String, error: Error?) {
        if let error { Log.error("Login başarısız: \(title)", error: error, category: .flow) }
        else { Log.error("Login başarısız: \(title) — \(message)", category: .flow) }
        step = .failed(title: title, message: message)
    }
}
