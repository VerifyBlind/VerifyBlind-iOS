import XCTest
@testable import VerifyBlind

/// `/api/public/app-config` sözleşmesinin istemci tarafı.
///
/// Asistan kapısı (parite denetimi 2026-09-03, O-10): asistan 2026-08-28'de sunucuda KAPATILDI ve
/// kapalıyken uç 200 + "SSS'ye bakın" mesajı döndürüyor — hata kodu değil. Yani istemci
/// `chatbot_enabled`'ı okumazsa kullanıcı hiçbir soruya cevap alamayan bir asistan görüyor.
/// Android'de bu ekrana giden bir giriş hiç yok; iOS'ta Yardım ekranındaki kart duruyordu.
///
/// Alanın YOKLUĞU kapıyı KAPALI bırakmalı (fail-closed): landing-site de okuma başarısız olursa
/// balonu göstermiyor.
final class AppConfigDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfigResponse {
        try JSONDecoder().decode(AppConfigResponse.self, from: Data(json.utf8))
    }

    func testChatbotFlagIsDecoded() throws {
        let cfg = try decode(#"{"chatbot_enabled": true}"#)
        XCTAssertEqual(cfg.chatbotEnabled, true)

        let off = try decode(#"{"chatbot_enabled": false}"#)
        XCTAssertEqual(off.chatbotEnabled, false)
    }

    func testMissingChatbotFlagLeavesTheGateClosed() throws {
        let cfg = try decode("{}")
        XCTAssertNil(cfg.chatbotEnabled)
        XCTAssertFalse(cfg.chatbotEnabled ?? false, "Alan yoksa asistan GİZLİ kalmalı.")
    }

    /// `store_url` Play adresini taşıyor ve bu modele BİLEREK alınmadı: alınırsa zorunlu güncelleme
    /// butonu iPhone kullanıcısını Play Store'a atar. Yeni alan eklerken bu kararın korunduğunu
    /// gösteren çapa.
    func testPlayStoreUrlDoesNotLeakIntoTheIosField() throws {
        let cfg = try decode(#"{"store_url": "https://play.google.com/x", "store_url_ios": "https://apps.apple.com/y"}"#)
        XCTAssertEqual(cfg.storeUrlIos, "https://apps.apple.com/y")
    }

    func testFullPayloadDecodes() throws {
        let cfg = try decode("""
        {"minimum_android_version":"1.0.1","minimum_ios_version":"1.0.2","store_url":"play",
         "store_url_ios":"apple","environment":"Production","chatbot_enabled":false,
         "demo_version_ios":"1.0.3","demo_version_android":"1.0.4","legal_terms_version":"1.1"}
        """)

        XCTAssertEqual(cfg.minimumIosVersion, "1.0.2")
        XCTAssertEqual(cfg.demoVersionIos, "1.0.3")
        XCTAssertEqual(cfg.legalTermsVersion, "1.1")
        XCTAssertEqual(cfg.chatbotEnabled, false)
    }
}
