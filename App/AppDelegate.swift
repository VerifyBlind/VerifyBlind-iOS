import UIKit
import UserNotifications

/// SwiftUI `@UIApplicationDelegateAdaptor` için UIApplicationDelegate implementasyonu.
/// APNs token kayıt callback'leri + foreground bildirim yönetimi.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Log.warning("Push izni hatası: \(error.localizedDescription)", category: .app)
                return
            }
            guard granted else {
                Log.info("Push bildirimi izni reddedildi.", category: .app)
                return
            }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// APNs token alındığında hex string olarak sakla ve sunucuya upsert et.
    /// Ticket koşulu YOK — uygulamanın kurulu olduğu her cihaz device_tokens'a yazılır,
    /// böylece kayıt olmamış kullanıcılar da broadcast bildirimlerine dahil olur.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppPrefs.apnsToken = hex
        Log.info("APNs token kaydedildi (\(hex.prefix(8))…)", category: .app)

        // Token'ı sunucuya upsert et. 8 saniyelik gecikme: eş zamanlı register/login
        // flow'unun rate-limit penceresinin (10/dk) dışına çıkmak için. try? intentional.
        Task {
            try? await Task.sleep(for: .seconds(8))
            _ = try? await VerifyAPI().handshake()
            Log.info("APNs token sunucuya gönderildi (arka plan).", category: .app)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.warning("APNs token alınamadı: \(error.localizedDescription)", category: .app)
    }
}

/// Uygulama ön plandayken bildirimleri banner + ses + rozet ile göster.
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }
}
