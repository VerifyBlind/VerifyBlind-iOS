import XCTest
@testable import VerifyBlind

/// Tam temizlik partner önbelleğini de götürüyor mu.
///
/// Regresyon zemini (parite denetimi 2026-09-03, O-3): `DataWipe.wipeAll()` "tüm yerel izleri
/// siler" diyordu ama partner önbelleğine hiç dokunmuyordu — `AppPrefs.clearAll()` sayılı bir
/// anahtar listesi siliyor ve `partner_cache` o listede değil. Android `performFullReset`
/// `partner_cache` + `VerifyBlind_Partners` prefs'lerini tümüyle siliyor. Kalan kayıtlar
/// kullanıcının hangi partnerlerle doğrulama yaptığını (ad + logo) cihazda tutuyordu.
///
/// `DataWipe.wipeAll()` değil `PartnerManager` sınanıyor: wipeAll Keychain, GRDB ve bulut SDK'larına
/// dokunuyor; ayrışmanın olduğu tek yer önbelleğin silinip silinmediği (`LegalTermsWipeTests` ile
/// aynı gerekçe).
final class PartnerCacheWipeTests: XCTestCase {

    override func tearDown() {
        PartnerManager.clear()
        super.tearDown()
    }

    private func partner(_ id: String) -> PartnerItem {
        PartnerItem(partnerId: id, name: "Test Partner \(id)", logoUrl: "",
                    logoBase64: nil, timestamp: 0)
    }

    func testClearRemovesEveryCachedPartner() {
        PartnerManager.save(partner("p1"))
        PartnerManager.save(partner("p2"))
        XCTAssertNotNil(PartnerManager.get("p1"))
        XCTAssertEqual(PartnerManager.all().count, 2)

        PartnerManager.clear()

        XCTAssertNil(PartnerManager.get("p1"), "Silme sonrası partner adı/logosu cihazda kalmamalı.")
        XCTAssertNil(PartnerManager.get("p2"))
        XCTAssertTrue(PartnerManager.all().isEmpty)
    }

    func testClearIsSafeWhenCacheIsEmpty() {
        PartnerManager.clear()
        // İkinci kez çağırmak patlamamalı: tam temizlik kısmî bozulmada da olabildiğince çok
        // şeyi silmeye devam etmeli.
        PartnerManager.clear()
        XCTAssertTrue(PartnerManager.all().isEmpty)
    }

    func testCacheStillWorksAfterBeingCleared() {
        PartnerManager.save(partner("p1"))
        PartnerManager.clear()
        PartnerManager.save(partner("p3"))

        XCTAssertEqual(PartnerManager.get("p3")?.partnerId, "p3")
        XCTAssertNil(PartnerManager.get("p1"))
    }
}
