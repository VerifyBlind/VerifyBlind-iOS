import XCTest
@testable import VerifyBlind

/// Tam temizlik hukuki metin kabulünü de götürüyor mu.
///
/// Neden test: kabul kaydı bir KANIT — sürüm ve zaman damgası taşıyor ve Ayarlar'da gösteriliyor.
/// Tam temizlik kullanıcıya ait her izi sildiği hâlde bu kayıt kalırsa cihaz, artık var olmayan bir
/// kullanıcı adına "şu sürümü şu tarihte kabul etti" demeye devam eder; telefon el değiştirdiyse bu
/// iddia yanlıştır. Ayrıca sıfırlama ekranının kendi vaadi "uygulama ilk hâline dönecek".
///
/// Bu tam olarak bozulmuştu: `AppPrefs.clearAll()` sayılı bir anahtar listesini siliyor ve hukuki
/// anahtarlar o listede değildi. Android tarafı `user_prefs`'in tamamını sildiği için orada
/// kendiliğinden gidiyor — yani iki platform ayrışmıştı. iOS pilotunun temiz kurulum turu (Tur 1)
/// yazılınca ortaya çıktı: sıfırlamadan sonra hukuki kapı geri gelmiyordu.
///
/// `DataWipe.wipeAll()` değil `LegalTerms` sınanıyor: wipeAll Keychain ve GRDB'ye dokunuyor, bu test
/// ise ayrışmanın olduğu tek yeri — kabul kaydının silinip silinmediğini — ölçüyor.
final class LegalTermsWipeTests: XCTestCase {

    private let versionKey = "legal_terms_accepted_version"
    private let atKey = "legal_terms_accepted_at"

    override func tearDown() {
        LegalTerms.clearAcceptance()
        super.tearDown()
    }

    func testClearAcceptanceRemovesBothVersionAndTimestamp() {
        LegalTerms.recordAcceptance(version: "1.0")
        XCTAssertEqual(LegalTerms.acceptedVersion, "1.0")
        XCTAssertNotNil(LegalTerms.acceptedAt)

        LegalTerms.clearAcceptance()

        // İKİSİ BİRDEN: sürüm silinip zaman damgası kalırsa Ayarlar özeti ve
        // ileride yazılacak kanıt mantığı yarım bir kayıtla çalışır.
        XCTAssertNil(LegalTerms.acceptedVersion)
        XCTAssertNil(LegalTerms.acceptedAt)
        XCTAssertNil(UserDefaults.standard.object(forKey: versionKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: atKey))
    }

    func testGateComesBackAfterAcceptanceIsCleared() {
        LegalTerms.recordAcceptance(version: "1.0")
        XCTAssertFalse(LegalTerms.needsAcceptance(acceptedVersion: LegalTerms.acceptedVersion,
                                                  requiredVersion: "1.0"),
                       "Kabul edilmiş sürümde kapı çıkmamalı.")

        LegalTerms.clearAcceptance()

        // Turun cihazda ölçtüğü şeyin birim testi karşılığı: temizlikten sonra
        // kapı GERİ GELMELİ.
        XCTAssertTrue(LegalTerms.needsAcceptance(acceptedVersion: LegalTerms.acceptedVersion,
                                                 requiredVersion: "1.0"),
                      "Kabul silindikten sonra kapı yeniden karşılamalı.")
    }

    func testClearAcceptanceIsSafeWhenNothingWasAccepted() {
        LegalTerms.clearAcceptance()
        // İkinci kez çağırmak patlamamalı: tam temizlik kısmî bozulmada da
        // olabildiğince çok şeyi silmeye devam etmeli.
        LegalTerms.clearAcceptance()
        XCTAssertNil(LegalTerms.acceptedVersion)
    }
}
