import SwiftUI

/// Uygulama-seviyesi oturum durumu (Android `MainActivity`'nin signedTicketJson / SecureStore
/// durumuna karşılık). Store'lardan türetilir; akışlar bittiğinde `refresh()` ile tazelenir.
@MainActor
final class AppState: ObservableObject {
    @Published var hasCard: Bool
    @Published var expiryDate: String?
    @Published var currentCardId: String?
    /// Demo modu (kartsız cihaz testi). Cihaz sürümü, admin panelden tanımlanan iOS demo sürümüyle
    /// birebir eşleşirse açılır (`loadConfig`'te belirlenir). Android `demoEnabled` paritesi.
    @Published var demoEnabled: Bool = false
    /// Register/Login tam-ekran akışı açıkken otomatik biyometrik kilidi bastır — NFC/kamera/Face ID
    /// sistem UI'sı akış ortasında .background tetikleyip sahte kilit/döngü yaratmasın.
    @Published var suppressAutoLock = false
    /// Universal Link ile gelen doğrulama URL'i (`https://app.verifyblind.com/request?nonce=...`).
    /// Set edilince RootView login akışını QR taramadan, bu URL ile başlatır. Akış bitince temizlenir.
    @Published var pendingVerifyURL: String?

    /// Launch-time enclave attestation engeli. nil = engel yok; dolu = kapatılamaz blok mesajı
    /// (Android CriticalError→finishAffinity paritesi). Yalnız GERÇEK doğrulama hatasında set edilir;
    /// erişilemezse (unreachable) BLOKLANMAZ (onaylı karar).
    @Published var attestationBlockMessage: String? = nil

    /// Minimum iOS sürümü — zorunlu güncelleme kontrolü için (Android `minimumVersion`).
    @Published var minimumIosVersion: String? = nil
    /// Sunucunun bildirdiği App Store adresi (`store_url_ios`). Boş/nil → gömülü adres kullanılır.
    /// Sunucudaki `store_url` PLAY adresidir ve bilinçli olarak okunmaz — bkz. `AppConfigResponse`.
    @Published var storeUrlIos: String? = nil

    /// Zorunlu güncelleme butonunun açacağı adres — her koşulda App Store (bkz. `Config`).
    var appStoreUrl: String { Config.appStoreUrl(serverProvided: storeUrlIos) }

    /// Sunucunun bildirdiği hukuki metin demeti sürümü (app-config). Boş/nil → gömülü taban geçerli.
    @Published var legalTermsServerVersion: String? = nil
    /// Cihazdaki kabul — UserDefaults'tan okunur, kabul anında güncellenir ki overlay kapansın.
    @Published var legalTermsAcceptedVersion: String? = LegalTerms.acceptedVersion

    /// Geçici toast mesajı (Android `Toast` paritesi) — RootView alt kısımda gösterir, ~2sn sonra siler.
    @Published var toastMessage: String?
    private var toastClearWorkItem: DispatchWorkItem?

    /// Kısa bir toast gösterir (ör. "Kimliğiniz doğrulandı"). Öncekini iptal edip yenisini kurar.
    func showToast(_ message: String) {
        toastClearWorkItem?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in self?.toastMessage = nil }
        toastClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    init() {
        hasCard = TicketStore.hasTicket
        expiryDate = AppPrefs.expiryDate
        currentCardId = SecureStore.getCardId()
    }

    func refresh() {
        hasCard = TicketStore.hasTicket
        expiryDate = AppPrefs.expiryDate
        currentCardId = SecureStore.getCardId()
    }

    /// Sunucu app-config'ini çeker; zorunlu güncelleme + demo butonu görünürlüğünü günceller.
    /// Android `MainViewModel.fetchAppConfig` paritesi.
    func loadConfig() async {
        do {
            let cfg = try await VerifyAPI.shared.appConfig()
            minimumIosVersion = cfg.minimumIosVersion
            storeUrlIos = cfg.storeUrlIos
            // Demo butonu: cihaz sürümü admin tanımlı iOS demo sürümüyle birebir eşleşirse görünür.
            let demoVersion = cfg.demoVersionIos ?? ""
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            demoEnabled = !demoVersion.isEmpty && demoVersion == current
            // Hukuki metin sürümü: yükseltilmişse overlay kendiliğinden yeniden açılır.
            legalTermsServerVersion = cfg.legalTermsVersion
        } catch {
            Log.warning("AppConfig yüklenemedi", error: error, category: .app)
        }
    }

    /// Kapının dayattığı hukuki metin sürümü — sunucu değeri yalnızca yükseltebilir.
    var requiredLegalTermsVersion: String {
        LegalTerms.requiredVersion(serverVersion: legalTermsServerVersion)
    }

    /// Kabul yoksa veya metinler güncellendiyse true → RootView engelleyici kapıyı gösterir.
    /// Ağ hiç çalışmasa bile gömülü taban sürüm yüzünden ilk açılışta true olur (fail-open yok).
    var needsLegalTermsAcceptance: Bool {
        LegalTerms.needsAcceptance(acceptedVersion: legalTermsAcceptedVersion,
                                   requiredVersion: requiredLegalTermsVersion)
    }

    /// Kabul kaydedildikten sonra çağrılır; yayımlanan değeri tazeleyerek kapıyı kapatır.
    func refreshLegalTermsAcceptance() {
        legalTermsAcceptedVersion = LegalTerms.acceptedVersion
    }

    /// Launch-time attestation gate — cold-start'ta arka planda çalışır (splash'ı bekletmez; Android
    /// açılış-handshake paritesi). Doğrulama başarısız → kapatılamaz blok mesajı; verified/unreachable
    /// → engel yok. Kimlik güvenliği register/login akışlarında koşulsuz zorlanır; bu yalnız erken UX.
    /// Kapı AYNI ANDA birden fazla koşamaz.
    ///
    /// App Attest sayacı her imzada artıyor ve sunucu kesin artan sıra bekliyor. İki sonda
    /// paralel giderse imzalar ağda sırasız varıyor ve ikincisi "sayaç gerilemesi (replay)" ile
    /// reddediliyor — cihazda 2026-08-26'da görüldü: aynı saniyede iki challenge, biri OK
    /// (count=13), diğeri RED. Meşru trafiğin replay koruması tetiklemesi hem akışı bozuyor hem
    /// de o sinyalin güvenilirliğini aşındırıyor.
    ///
    /// İki kaynak var ve ikisi çakışabiliyordu: uygulama öne geldiğinde otomatik koşan kapı ve
    /// kullanıcının bastığı "Yeniden Dene" düğmesi.
    private var attestationGateRunning = false

    func runAttestationGate() async {
        if attestationGateRunning { return }
        attestationGateRunning = true
        defer { attestationGateRunning = false }

        switch await HandshakeService.shared.probeAttestation() {
        case .failed(_, let message):
            attestationBlockMessage = message
        case .verified, .unreachable:
            attestationBlockMessage = nil
        }
    }

    /// Mevcut sürüm sunucunun belirlediği minimumdan eskiyse true (Android `isVersionOlder`).
    var needsForceUpdate: Bool {
        guard let minVersion = minimumIosVersion, !minVersion.isEmpty,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return false
        }
        let cur = current.split(separator: ".").compactMap { Int($0) }
        let min = minVersion.split(separator: ".").compactMap { Int($0) }
        for i in 0..<Swift.max(cur.count, min.count) {
            let c = i < cur.count ? cur[i] : 0
            let m = i < min.count ? min[i] : 0
            if c < m { return true }
            if c > m { return false }
        }
        return false
    }
}
