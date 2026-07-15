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

        CloudBackupManager.registerDefaults()
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

    private static func topMost(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController { return topMost(from: presented) }
        if let nav = vc as? UINavigationController, let top = nav.visibleViewController { return topMost(from: top) }
        if let tab = vc as? UITabBarController, let sel = tab.selectedViewController { return topMost(from: sel) }
        return vc
    }
}
