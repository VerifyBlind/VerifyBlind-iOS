import XCTest
@testable import VerifyBlind

/// "İstek iptal edildi" (-999) bir arıza değildir → Sentry'ye event gitmez, yalnız breadcrumb.
///
/// Regresyon zemini: VERIFYBLIND-IOS-1R/47/48/3G/3H/3J — kapanan ekranın ya da yeni bir deep-link'in
/// iptal ettiği istekler `APIClientError.network("Code(rawValue: -999)")` ve ham `NSURLErrorDomain
/// -999` olarak warning seviyesinde 6 ayrı issue açıyordu.
///
/// Sınıflandırma `NetworkStatus.isRequestCancellation`'da; `Log.failure` seviyesi ve
/// `SentryBridge.capture` kapısı ikisi de onu çağırır.
final class RequestCancellationPolicyTests: XCTestCase {

    // MARK: - İptal tanıma

    func testURLErrorCancelledIsCancellation() {
        XCTAssertTrue(NetworkStatus.isRequestCancellation(URLError(.cancelled)))
    }

    func testRawNSURLErrorCancelledIsCancellation() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(NetworkStatus.isRequestCancellation(ns))
        XCTAssertEqual(NSURLErrorCancelled, -999)
    }

    func testAPIClientWrappedCancellationIsCancellation() {
        let wrapped = APIClientError.transport(URLError(.cancelled))
        XCTAssertTrue(wrapped.isCancelled)
        XCTAssertTrue(NetworkStatus.isRequestCancellation(wrapped))
    }

    /// Sahadaki yük birebir bu dizeydi; `transport` aynı biçimi üretmeye devam etmeli.
    func testAPIClientCancellationPayloadMatchesFieldEvents() {
        guard case .network(let detail) = APIClientError.transport(URLError(.cancelled)) else {
            return XCTFail("transport(.network) üretmedi")
        }
        XCTAssertEqual(detail, "Code(rawValue: -999)")
        XCTAssertTrue(APIClientError.network("Code(rawValue: -999)").isCancelled)
    }

    func testUnderlyingCancellationIsCancellation() {
        let wrapped = NSError(domain: "app.verifyblind.wrapper", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        XCTAssertTrue(NetworkStatus.isRequestCancellation(wrapped))
    }

    // MARK: - İptal OLMAYANLAR (gerçek sinyal warning/error kalmalı)

    func testOtherTransportErrorsAreNotCancellation() {
        XCTAssertFalse(NetworkStatus.isRequestCancellation(URLError(.timedOut)))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(APIClientError.transport(URLError(.timedOut))))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(APIClientError.network("HTTP olmayan yanıt")))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    func testApplicationErrorsAreNotCancellation() {
        XCTAssertFalse(NetworkStatus.isRequestCancellation(nil))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(APIClientError.decoding))
        XCTAssertFalse(NetworkStatus.isRequestCancellation(APIClientError.http(500, nil)))
        // Başka bir domain'de -999 iptal DEĞİLDİR.
        XCTAssertFalse(NetworkStatus.isRequestCancellation(NSError(domain: "other", code: -999)))
    }

    func testCancellationBeyondDepthCapIsIgnored() {
        // Derinlik tavanı (5) sebep zincirini sınırlar; çok derine gömülmüş iptal aranmaz.
        var chain: NSError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        for i in 1...10 {
            chain = NSError(domain: "wrap", code: i, userInfo: [NSUnderlyingErrorKey: chain])
        }
        XCTAssertFalse(NetworkStatus.isRequestCancellation(chain))
    }

    // MARK: - Sentry otomatik HTTP hata hedefleri (VERIFYBLIND-IOS-4)

    func testFailedRequestTargetsAreOnlyOwnAPIHost() {
        let targets = LogBootstrap.failedRequestTargets(apiBaseURL: URL(string: "https://api.verifyblind.com"))
        XCTAssertEqual(targets, ["api.verifyblind.com"])
        // Üçüncü taraf (ML Kit telemetrisi) hiçbir hedefle eşleşmemeli — Sentry dize hedefini
        // URL içinde arar.
        let google = "https://www.googleapis.com/experimentsandconfigs/v1/getExperimentsAndConfigs"
        XCTAssertFalse(targets.contains { google.contains($0) })
        XCTAssertTrue(targets.contains { "https://api.verifyblind.com/api/Verify/register".contains($0) })
    }

    func testFailedRequestTargetsFollowConfiguredHost() {
        let targets = LogBootstrap.failedRequestTargets(apiBaseURL: URL(string: "https://dev-api.example.test/base"))
        XCTAssertEqual(targets, ["dev-api.example.test"])
    }

    func testFailedRequestTargetsNeverEmpty() {
        // Boş liste yakalamayı tamamen kapatırdı; kendi 5xx'lerimiz kaybolmamalı.
        XCTAssertEqual(LogBootstrap.failedRequestTargets(apiBaseURL: nil), ["api.verifyblind.com"])
    }
}
