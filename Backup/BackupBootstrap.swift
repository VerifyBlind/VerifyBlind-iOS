import Foundation
import UIKit
import SwiftyDropbox
import GoogleSignIn

/// Bulut yedekleme SDK'larının uygulama açılışında konfigürasyonu + OAuth redirect yönlendirmesi.
/// `VerifyBlindApp.init()`'te `configure()`, `onOpenURL`'de `handleOpenURL(_:)` çağrılır.
enum BackupBootstrap {

    static func configure() {
        // Dropbox app key (SwiftyDropbox token'ları Keychain'de saklar; authorizedClient geri yüklenir).
        let dropboxKey = Config.dropboxAppKey
        if !dropboxKey.isEmpty {
            DropboxClientsManager.setupWithAppKey(dropboxKey)
        } else {
            Log.info("BackupBootstrap: DROPBOX_IOS_APP_KEY boş — Dropbox devre dışı", category: .app)
        }

        // Google Sign-In client id + önceki oturumu sessizce geri yükle.
        let googleClientID = Config.googleClientID
        if !googleClientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: googleClientID)
            GIDSignIn.sharedInstance.restorePreviousSignIn()
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
