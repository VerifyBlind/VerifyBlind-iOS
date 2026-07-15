import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// App-to-app deeplink akışı mı (true → geri-dönüş URL'i onurlandırılır).
    let isDeepLink: Bool
    /// Deeplink'teki geri-dönüş URL'i (ör. "verifyblinddemo://callback"). Yalnız isDeepLink'te kullanılır.
    private var returnUrl: String?
    /// Partner-info'dan gelen kayıtlı return şeması — return URL doğrulaması için (fail-closed).
    private var partnerAppReturnScheme: String?
    /// Terminal duruma (success/reject/fail) ulaşıldı mı — akış kapanırken çift-iptali önler (Item 3b).
    private var terminal = false

    /// `initialPayload` (deep-link URL) verilirse QR taramayı atla, doğrudan o nonce ile başla.
    init(initialPayload: String? = nil) {
        isDeepLink = (initialPayload != nil)
        if let initialPayload {
            step = .loadingPartner   // kamera adımı gösterilmesin
            onQr(initialPayload)
        }
    }

    // MARK: - QR

    func onQr(_ payload: String) {
        guard let parsed = QRPayloadParser.parse(payload) else {
            fail(title: L.t("invalid_request"), message: L.t("invalid_qr"), error: nil)
            return
        }
        nonce = parsed.nonce
        pkHash = parsed.pkHash
        returnUrl = parsed.returnUrl
        step = .loadingPartner
        Task { await fetchPartner() }
    }

    private func fetchPartner() async {
        guard TicketStore.hasTicket else {
            // Partner widget'ı QR TTL'e kadar boş poll'da kalmasın — relay'e iptal bildir (Android paritesi).
            Task { await cancelPop(reason: "no_card_registered") }
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
            partnerAppReturnScheme = info.appReturnScheme // app-return doğrulaması için kayıtlı şema
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
        terminal = true
        Task { await cancelPop() }
        step = .rejected
    }

    // MARK: - App-to-app geri dönüş + iptal (Item 2b / Item 3b)

    /// Deeplink app-return: return URL'in şeması partner'ın kayıtlı şemasıyla eşleşirse (fail-closed →
    /// açık-yönlendirme önlemi) return URL'i nonce+status ile açar → partner uygulaması öne gelir.
    @discardableResult
    func openReturnIfValid(status: String) -> Bool {
        guard isDeepLink,
              let ret = returnUrl, !ret.isEmpty,
              let registered = partnerAppReturnScheme, !registered.isEmpty,
              var comps = URLComponents(string: ret),
              let scheme = comps.scheme,
              scheme.caseInsensitiveCompare(registered) == .orderedSame
        else { return false }

        var items = comps.queryItems ?? []
        if !nonce.isEmpty { items.append(URLQueryItem(name: "nonce", value: nonce)) }
        items.append(URLQueryItem(name: "status", value: status))
        comps.queryItems = items
        guard let url = comps.url else { return false }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
        return true
    }

    /// Login akışı terminal duruma ulaşmadan kapatıldıysa (kullanıcı vazgeçti) nonce'u iptal et →
    /// partner poll'u anında "cancelled" alır, "lütfen bekleyiniz"de takılmaz (Item 3b).
    func onFlowDismissed() {
        guard !terminal, !nonce.isEmpty else { return }
        terminal = true
        Task { await cancelPop() }
    }

    // MARK: - Login finalize

    private func completeLogin() async {
        do {
            let enclavePubKey = try await HandshakeService.shared.ensureLoginHandshake()
            // Holder-of-key (Y-4): bu login'e özgü mesaj — enclave UserPubKey ile doğrular.
            // Kanonik form Android/enclave ile BYTE-BYTE aynı olmalı: "VBLOK1|{nonce}|{pk_hash}|{ts}".
            let sigTs = Int64(Date().timeIntervalSince1970)
            let hokMessage = "VBLOK1|\(nonce)|\(pkHash ?? "")|\(sigTs)"
            // TEK biyometrik promptla decrypt + imza.
            let (signedTicketJson, userSig) = try await TicketStore.decryptSignedTicketAndSign(
                message: hokMessage, reason: L.t("biometric_subtitle_decrypt"))
            let wrapper = try LoginWrapperBuilder.build(signedTicketJson: signedTicketJson, nonce: nonce, pkHash: pkHash)

            let (aesBlob, aesKey) = try CryptoUtils.aesEncrypt(wrapper)
            let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: enclavePubKey)
            let hybrid = HybridContent(encKey: encKey, blob: aesBlob)
            let hybridJson = String(decoding: try JSONEncoder().encode(hybrid), as: UTF8.self)

            let req = LoginRequest(encrSignedTicket: hybridJson, nonce: nonce, userSignature: userSig, userSigTs: sigTs)
            try await VerifyAPI.shared.login(req)

            recordHistory()
            terminal = true
            step = .success
        } catch {
            if case let APIClientError.http(_, body) = error, body?.errorCode == "ERR_TICKET_REVOKED" {
                // Ticket sunucu tarafında iptal edildi → yerel kaydı sil. Akış kapanınca RootView'in
                // onDismiss'i AppState.refresh() çağırır → kayıtsız (kimlik ekleme) durumuna dönülür.
                TicketStore.clear()
                fail(title: L.t("ticket_revoked_title"),
                     message: body?.error ?? L.t("ticket_revoked_message"),
                     error: nil)
                return
            }
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

    private func cancelPop(reason: String? = nil) async {
        do { try await VerifyAPI.shared.cancelPop(PopCancelRequest(nonce: nonce, reason: reason)) }
        catch { Log.warning("cancelPop başarısız (yok sayıldı): \(error.localizedDescription)", category: .flow) }
    }

    private func fail(title: String, message: String, error: Error?) {
        // Seviye hatanın türünden gelir (geçersiz QR/kart yok/ağ/biyometrik iptal = warning/info, gerçek arıza = error).
        Log.failure(error != nil ? "Login başarısız: \(title)" : "Login başarısız: \(title) — \(message)",
                    error: error, category: .flow)
        terminal = true
        step = .failed(title: title, message: message)
    }
}
