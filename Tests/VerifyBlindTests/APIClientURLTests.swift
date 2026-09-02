import XCTest
@testable import VerifyBlind

/// origin + path birleşiminin sözleşmesi.
///
/// Regresyon: `FlowTelemetry` uçları path'i baştaki `/` ile veriyordu ("/api/Verify/flow-event").
/// Birleştirme `origin + "/" + path` olduğu için URL `https://host//api/Verify/flow-event` oluyor,
/// ASP.NET Core boş ilk segment yüzünden route'u EŞLEŞTİRMİYOR (canlıda 404; doğru path 400 döner).
/// Telemetri hatayı yuttuğu için bu sessizce aylarca sürdü: admin portaldaki kart ekleme hunisi
/// yalnız Android'i saydı. Baştaki slash artık normalize edilir — sonraki uç aynı tuzağa düşmesin.
final class APIClientURLTests: XCTestCase {

    private let origin = URL(string: "https://api.verifyblind.com")!

    func testLeadingSlashDoesNotProduceDoubleSlash() {
        XCTAssertEqual(
            APIClient.url(origin: origin, path: "/api/Verify/flow-event").absoluteString,
            "https://api.verifyblind.com/api/Verify/flow-event",
            "Baştaki slash çift slash üretmemeli — relay 404 döner ve telemetri sessizce kaybolur"
        )
    }

    func testPathWithoutLeadingSlashUnchanged() {
        XCTAssertEqual(
            APIClient.url(origin: origin, path: "api/Verify/register").absoluteString,
            "https://api.verifyblind.com/api/Verify/register"
        )
    }

    /// Query string KORUNMALI — `appendingPathComponent` "?"yi encode edip bozduğu için
    /// birleştirme bilerek string düzeyinde yapılıyor.
    func testQueryStringPreserved() {
        XCTAssertEqual(
            APIClient.url(origin: origin, path: "api/kvkk/privacy-notice?format=html").absoluteString,
            "https://api.verifyblind.com/api/kvkk/privacy-notice?format=html"
        )
    }

    func testPortPreserved() {
        let local = URL(string: "http://10.0.2.2:5102")!
        XCTAssertEqual(
            APIClient.url(origin: local, path: "/api/public/app-config").absoluteString,
            "http://10.0.2.2:5102/api/public/app-config"
        )
    }
}
