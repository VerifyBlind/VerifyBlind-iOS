import XCTest
@testable import VerifyBlind

/// "İnternet yok" ile "bizde arıza var" ayrımının sözleşmesi.
///
/// Regresyon zemini: kullanıcı uçak modundayken akış, sistemin ham hata metnini gösteriyordu
/// (`Couldn't reach the internet.` / Android'de `Unable to resolve host "api.verifyblind.com"`).
/// Metin hem teknik hem de sunucu adını içerdiği için servis çökmüş izlenimi veriyordu; ayrıca aynı
/// hata Sentry'ye event olarak düşüp ücretsiz plan kotasını yakıyordu (VERIFYBLIND-IOS-3G/3H,
/// VERIFYBLIND-ANDROID-12).
///
/// Aşağıdaki sınıflandırma bozulursa iki arıza birden geri gelir: yanlış kullanıcı mesajı VE
/// gereksiz Sentry gürültüsü.
final class NetworkErrorPolicyTests: XCTestCase {

    // MARK: - Taşıma hatası tanıma

    func testURLErrorIsTransportFailure() {
        XCTAssertTrue(NetworkStatus.isTransportFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetworkStatus.isTransportFailure(URLError(.cannotFindHost)))
        XCTAssertTrue(NetworkStatus.isTransportFailure(URLError(.timedOut)))
    }

    func testAPIClientNetworkErrorIsTransportFailure() {
        XCTAssertTrue(NetworkStatus.isTransportFailure(APIClientError.network("-1009")))
    }

    func testWrappedURLErrorIsTransportFailure() {
        let wrapped = NSError(
            domain: "app.verifyblind.wrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)]
        )
        XCTAssertTrue(NetworkStatus.isTransportFailure(wrapped))
    }

    func testApplicationFailuresAreNotTransportFailures() {
        // Bu ayrım teşhis için kritik: her hatayı "bağlantı sorunu" saymak, bir kod arızasını
        // kullanıcı tarafında ağ sorunu gibi gösterir ve gerçek bug görünmez olur.
        XCTAssertFalse(NetworkStatus.isTransportFailure(APIClientError.decoding))
        XCTAssertFalse(NetworkStatus.isTransportFailure(APIClientError.http(500, nil)))
        XCTAssertFalse(NetworkStatus.isTransportFailure(nil))
    }

    // MARK: - Kullanıcıya gösterilen metin

    func testTransportFailureShowsCanonicalConnectionMessage() {
        let message = UserFacingError.message(for: URLError(.notConnectedToInternet))

        XCTAssertEqual(message, L.t("error_connection_generic"))
        XCTAssertFalse(message.contains("verifyblind.com"), "Kullanıcı mesajı sunucu adı içermemeli")
        XCTAssertEqual(UserFacingError.title(for: URLError(.notConnectedToInternet)),
                       L.t("connection_error_title"))
    }

    func testServerFailureIsNotShownAsConnectionProblem() {
        // 5xx bizim tarafımız: "bağlantını kontrol et" demek kullanıcıyı yanlış yere yollar.
        let error = APIClientError.http(503, nil)

        XCTAssertEqual(UserFacingError.message(for: error), L.t("error_service_unavailable"))
        XCTAssertEqual(UserFacingError.title(for: error), L.t("error_server_unavailable_title"))
    }

    func testInternalFailureFallsBackToInternalMessage() {
        struct Boom: Error {}

        XCTAssertEqual(UserFacingError.message(for: Boom()), L.t("error_internal_generic"))
        XCTAssertEqual(UserFacingError.title(for: Boom()), L.t("error_system_title"))
    }

    // MARK: - Akışa özgü yedek metin

    func testTransportFailureIgNoresFlowSpecificFallback() {
        // ASIL REGRESYON: kayıt akışının son adımı bu fonksiyonu ATLAYIP doğrudan
        // "error_registration_server" basıyordu. Sonuç: uçak modundaki kullanıcıya
        // "Kayıt sırasında bir sunucu hatası oluştu" — kendi bağlantısızlığı bizim
        // arızamız gibi sunuluyordu.
        let message = UserFacingError.message(for: URLError(.notConnectedToInternet),
                                              internalFallbackKey: "error_registration_server")
        XCTAssertEqual(message, L.t("error_connection_generic"))

        let title = UserFacingError.title(for: URLError(.notConnectedToInternet),
                                         internalFallbackKey: "registration_failed_status")
        XCTAssertEqual(title, L.t("connection_error_title"))
    }

    func testInternalFailureUsesFlowSpecificFallback() {
        // Yedek metnin var olma sebebi: çağıranın kendi bağlamını korumak için bu
        // fonksiyonu atlamak zorunda kalmaması.
        struct Boom: Error {}

        XCTAssertEqual(UserFacingError.message(for: Boom(),
                                               internalFallbackKey: "error_registration_server"),
                       L.t("error_registration_server"))
        XCTAssertEqual(UserFacingError.title(for: Boom(),
                                             internalFallbackKey: "registration_failed_status"),
                       L.t("registration_failed_status"))
    }

    func testApiErrorTextWinsOverFlowSpecificFallback() {
        // Sunucunun kendi açıkladığı hata, akışın jenerik metninden daha bilgilendirici.
        XCTAssertEqual(UserFacingError.message(for: APIClientError.http(503, nil),
                                               internalFallbackKey: "error_registration_server"),
                       L.t("error_service_unavailable"))
    }

    func testLocalizedKeysResolve() {
        // L.t anahtarı bulamazsa anahtarın kendisini döndürür — sessiz fallback'i burada yakala.
        for key in ["error_connection_generic", "error_internal_generic",
                    "connection_error_title", "error_system_title",
                    "error_registration_server", "error_demo_server",
                    "registration_failed_status", "error_demo_registration_title"] {
            XCTAssertNotEqual(L.t(key), key, "Localizable.strings içinde eksik anahtar: \(key)")
        }
    }
}
