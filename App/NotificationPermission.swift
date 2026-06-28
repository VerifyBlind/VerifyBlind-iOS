import UIKit
import UserNotifications

/// Bildirim izni — soft-ask (priming) akışı.
///
/// Sistem izin prompt'u uygulama başında DEĞİL, kullanıcı wallet'taki banner'da
/// "İzin Ver"e bastığında tetiklenir (Apple + Google önerisi: bağlamlı izin = yüksek kabul,
/// kaza tap yok). Sistem prompt'u bir kez gösterilince durum `.notDetermined` olmaktan çıkar
/// ve banner kalıcı olarak kaybolur.
enum NotificationPermission {

    /// Mevcut sistem izin durumu.
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Soft-ask banner'ı gösterilmeli mi? Yalnız sistem hiç sormamışken (.notDetermined)
    /// ve snooze süresi dolmuşken true döner.
    static func shouldShowSoftAsk() async -> Bool {
        guard await status() == .notDetermined else { return false }
        return Date().timeIntervalSince1970 >= AppPrefs.notifSoftAskNextShow
    }

    /// "Daha Sonra" — banner'ı 2 gün ertele.
    static func snooze() {
        AppPrefs.notifSoftAskNextShow = Date().timeIntervalSince1970 + 2 * 24 * 3600
    }

    /// "İzin Ver" — sistem prompt'unu göster, izin verilirse APNs'e kaydol.
    static func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                Log.info("Push bildirimi izni reddedildi.", category: .app)
                return
            }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            Log.warning("Push izni hatası: \(error.localizedDescription)", category: .app)
        }
    }
}
