import XCTest
@testable import VerifyBlind

final class SmokeTests: XCTestCase {
    func testConfigLoads() {
        XCTAssertFalse(Config.apiBaseURL.absoluteString.isEmpty, "API_BASE_URL boş")
    }

    func testLogCategoriesExist() {
        XCTAssertEqual(LogCategory.allCases.count, 8)
    }

    /// Regresyon: `Flow.login` kimliği payload'a BAĞLI olmalı. Sabit id ile (eski `rawValue`),
    /// QR kamerası zaten açıkken gelen deep-link'te SwiftUI view kimliğini koruyor,
    /// `LoginFlowView`'un `@StateObject` vm'i yeniden yaratılmıyor ve `initialPayload` sessizce
    /// düşüyordu → kamera açık kalıp doğrulama hiç başlamıyordu.
    func testLoginFlowIdentityChangesWithPayload() {
        let urlA = "https://app.verifyblind.com/request?nonce=A"
        let urlB = "https://app.verifyblind.com/request?nonce=B"

        let manualScan = RootView.Flow.login(payload: nil).id
        let deepLinkA = RootView.Flow.login(payload: urlA).id
        let deepLinkB = RootView.Flow.login(payload: urlB).id

        XCTAssertNotEqual(manualScan, deepLinkA, "Deep-link, açık QR kamerasını preempt edemez")
        XCTAssertNotEqual(deepLinkA, deepLinkB, "Yeni nonce, süren login'i preempt edemez")
        XCTAssertEqual(deepLinkA, RootView.Flow.login(payload: urlA).id, "Aynı payload kararlı id vermeli")
        XCTAssertNotEqual(deepLinkA, RootView.Flow.register.id)
    }

    /// Manuel Yedekle/Geri Yükle modelinde yedekleme banner'ı DAİMA görünür bir giriş noktasıdır
    /// (sürekli bulut bağlantısı durumu kaldırıldı).
    func testBackupBannerAlwaysShown() {
        XCTAssertTrue(HistoryView.shouldShowBackupBanner(),
                      "Manuel modelde yedekleme banner'ı daima görünür")
    }

    /// Çapraz-platform kripto sözleşmesi: iOS `.vfbackup` çekirdeği RFC 7914 golden vektörlerini
    /// (Android `BackupCryptoTest` ile aynı) üretmeli.
    func testBackupCryptoGoldenVectors() {
        XCTAssertNil(BackupCrypto.selfTestGoldenVectors(), "PBKDF2/AES-GCM golden vektörleri sapmamalı")
    }

    /// Regresyon: zorunlu güncelleme butonu bir dönem sunucunun `store_url`'ünü açıyordu; o alan
    /// PLAY adresini taşır, yani iPhone kullanıcısı yanlış mağazaya gidiyordu. Sunucu ne gönderirse
    /// göndersin (veya hiç göndermesin), hedef App Store olmalı.
    func testForceUpdateAlwaysTargetsAppStore() {
        XCTAssertTrue(Config.appStoreFallbackUrl.contains("apps.apple.com"),
                      "Gömülü yedek adres App Store olmalı")
        XCTAssertFalse(Config.appStoreFallbackUrl.contains("play.google.com"),
                       "Gömülü yedek adres asla Play olmamalı")
        // Gerçek App Store kimliği (2026-08-18 yayın onayı). Repo'nun ilk commit'inden beri taşınan
        // `id6743770042` UYDURMAYDI; kimse doğrulamadığı için .env.example'a ve testlere yayılmıştı.
        XCTAssertTrue(Config.appStoreFallbackUrl.contains("id6776778178"),
                      "App Store kimliği sapmış — doğrulanmamış bir id geri gelmiş olabilir")

        // Sunucu APPLE_STORE_URL'i tanımlamamış → gömülü adres.
        XCTAssertEqual(Config.appStoreUrl(serverProvided: nil), Config.appStoreFallbackUrl)
        XCTAssertEqual(Config.appStoreUrl(serverProvided: ""), Config.appStoreFallbackUrl)
        // Env'e kazara boşluk girmesi de "tanımsız" sayılmalı; boşluktan URL olmaz.
        XCTAssertEqual(Config.appStoreUrl(serverProvided: "   "), Config.appStoreFallbackUrl)

        // Sunucu adres verdiyse o kullanılır (adres panelden/env'den yönetilebilsin diye).
        let custom = "https://apps.apple.com/tr/app/verifyblind/id6776778178"
        XCTAssertEqual(Config.appStoreUrl(serverProvided: custom), custom)
    }
}
