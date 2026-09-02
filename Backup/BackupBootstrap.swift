import Foundation
import UIKit
import SwiftyDropbox
import GoogleSignIn

/// Bulut yedekleme SDK'larının konfigürasyonu + OAuth redirect yönlendirmesi.
/// `VerifyBlindApp.init()`'te `configure()`, `onOpenURL`'de `handleOpenURL(_:)` çağrılır.
/// Dropbox kurulumu bilinçli olarak açılış dışında — bkz `ensureDropboxConfigured()`.
enum BackupBootstrap {

    /// SwiftyDropbox kurulumu — açılışta DEĞİL, ilk kullanımda. `setupWithAppKey` Keychain
    /// erişilebilirlik migrasyonu yapar (`SecItemUpdate` → securityd'ye senkron XPC); açılış
    /// yolunda çağrılınca Düşük Güç Modu'nda ana thread ilk frame'den önce 2sn+ bloklanıyordu.
    /// `static let` = swift_once → tek sefer, thread-safe. Token'lar Keychain'de; kurulum
    /// `authorizedClient`'ı geri yükler.
    private static let dropboxSetup: Bool = {
        let dropboxKey = Config.dropboxAppKey
        guard !dropboxKey.isEmpty else {
            Log.info("BackupBootstrap: DROPBOX_IOS_APP_KEY boş — Dropbox devre dışı", category: .app)
            return false
        }
        DropboxClientsManager.setupWithAppKey(dropboxKey)
        return true
    }()

    /// Dropbox SDK'sına dokunan her giriş noktası önce bunu çağırır. false = Dropbox devre dışı.
    @discardableResult
    static func ensureDropboxConfigured() -> Bool { dropboxSetup }

    static func configure() {
        // Google Sign-In client id + önceki oturumu sessizce geri yükle.
        let googleClientID = Config.googleClientID
        if !googleClientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: googleClientID)
            GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in }   // ObjC completion zorunlu (default yok)
        } else {
            Log.info("BackupBootstrap: GOOGLE_IOS_CLIENT_ID boş — Google Drive devre dışı", category: .app)
        }
    }

    /// `onOpenURL` — OAuth redirect'ini ilgili sağlayıcıya yönlendirir. İşlendiyse true.
    @discardableResult
    static func handleOpenURL(_ url: URL) -> Bool {
        if DropboxProvider.handleRedirect(url) { return true }
        if GoogleDriveProvider.handleRedirect(url) { return true }
        return false
    }
}

extension UIApplication {
    /// Sunum için en üstteki view controller — SwiftUI'de OAuth/GoogleSignIn present etmek gerekir.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = (scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)
            ?? (scenes.first as? UIWindowScene)
        let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController
        guard let root else { return nil }
        return topMost(from: root)
    }

    /// Sunum yapılabilir en üst controller — GEÇİŞ BİTENE KADAR bekler.
    ///
    /// `topViewController()` anlık bir fotoğraf çekiyor ve kapanmakta olan bir sheet'i de "en üst"
    /// sayabiliyor. OAuth ekranı böyle bir controller'ın üstünde açılınca, o controller kapanırken
    /// OAuth'u da beraberinde götürüyor: kullanıcı Google'ın izin sorusunu ~100 ms görüp
    /// kayboluşunu izliyor (cihaz raporu 2026-08-26/27, iki build boyunca sürdü).
    ///
    /// ⚠️ Yalnız `isBeingDismissed` beklemek YETMEZ ve ilk denemede bu yüzden çözülmedi: sistem
    /// kimlik doğrulama ekranı bizim süreçte bir `UIViewController` DEĞİL, dolayısıyla hiyerarşide
    /// "kapanıyor" görünen bir şey yok — beklenecek bir şey bulunamıyordu.
    ///
    /// Doğru ölçütü kullanıcının gözlemi verdi (2026-08-27): yedeği ŞİFRELİ alırken sorun yok,
    /// şifresiz alırken var. Fark PBKDF2 — şifreli yolda anahtar türetme yüzlerce milisaniye
    /// sürüyor ve PIN ekranının yıkılmasına doğal bir pay bırakıyor. Şifresiz yolda o pay yok ve
    /// OAuth, sistem ekranı daha yıkılırken sunulup atılıyor. Yani beklenmesi gereken şey bir
    /// controller değil, uygulamanın gerçekten öne gelip DURULMASI.
    ///
    /// Zaman aşımında elde olanı döndürür: sunumu hiç denememektense denemek yeğdir.
    /// Uygulamanın KESİNTİSİZ öne gelmiş kalması gereken süre. Sistem kimlik doğrulama ekranı
    /// (Face ID / PIN) süreç DIŞINDA çiziliyor; kapanışı bittikten sonra pencere hiyerarşisinin
    /// oturması için kısa bir pay gerekiyor.
    private static let settleWindow: TimeInterval = 0.35

    @MainActor
    static func settledTopViewController(timeout: TimeInterval = 3.0) async -> UIViewController? {
        let deadline = Date().addingTimeInterval(timeout)
        var activeSince: Date?

        while Date() < deadline {
            if UIApplication.shared.applicationState == .active {
                if activeSince == nil { activeSince = Date() }
            } else {
                activeSince = nil          // öne gelme kesildi → sayacı sıfırla
            }

            if let since = activeSince,
               Date().timeIntervalSince(since) >= settleWindow,
               let vc = topViewController(), !vc.isBeingDismissed, !vc.isBeingPresented {
                return vc
            }
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms
        }
        return topViewController()
    }

    private static func topMost(from vc: UIViewController) -> UIViewController {
        // Kapanmakta olan bir controller SUNUCU olarak seçilemez — üstüne sunulan her şey
        // onunla birlikte kaldırılır.
        if let presented = vc.presentedViewController, !presented.isBeingDismissed {
            return topMost(from: presented)
        }
        if let nav = vc as? UINavigationController, let top = nav.visibleViewController { return topMost(from: top) }
        if let tab = vc as? UITabBarController, let sel = tab.selectedViewController { return topMost(from: sel) }
        return vc
    }
}
