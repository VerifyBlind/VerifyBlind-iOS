import XCTest
@testable import VerifyBlind

/// Kart ekleme akışında geri tuşunun sözleşmesi.
///
/// Regresyon zemini: geri oku hangi adımda olursa olsun akıştan TAMAMEN çıkıyordu. NFC
/// adımında kartı okutamayan kullanıcı bir ekran geri dönemiyor, kaydı el sıkışma dahil
/// baştan yapıyordu. Android'de aynı davranış hardware geri tuşunda vardı ve
/// `btnStepperBack` ile adım adım geriye çevrildi; bu testler iOS tarafını ona bağlar.
@MainActor
final class RegisterBackNavigationTests: XCTestCase {

    func testNfcStepsBackToMrz() {
        let vm = RegisterViewModel(isDemo: true)
        vm.step = .nfc

        XCTAssertTrue(vm.stepBack())
        XCTAssertEqual(vm.step, .mrz)
    }

    func testMrzStepsBackToPreparation() {
        let vm = RegisterViewModel(isDemo: true)
        vm.step = .mrz

        XCTAssertTrue(vm.stepBack())
        XCTAssertEqual(vm.step, .preparation)
    }

    func testPreparationHasNowhereToGoBackTo() {
        // false = "geri gidilecek adım yok" → çağıran akıştan çıkar. Burada true dönmek,
        // kullanıcıyı hazırlık ekranında kilitlerdi.
        let vm = RegisterViewModel(isDemo: true)
        vm.step = .preparation

        XCTAssertFalse(vm.stepBack())
        XCTAssertEqual(vm.step, .preparation)
    }

    func testLaterStepsDoNotStepBack() {
        // Geri oku yalnızca hazırlık/MRZ/NFC ekranlarında görünüyor; sözleşme yine de
        // burada tutulur ki ileride bir ekran eklendiğinde sessizce yanlış yere dönmesin.
        for step in [RegisterViewModel.Step.liveness, .processing, .success] {
            let vm = RegisterViewModel(isDemo: true)
            vm.step = step
            XCTAssertFalse(vm.stepBack(), "\(step) geri adım üretmemeli")
        }
    }

    func testSteppingBackFromNfcClearsRetryState() {
        // Sayaçlar sıfırlanmazsa geri dönüp tekrar gelen kullanıcı önceki denemelerin
        // bütçesini tüketmiş halde başlar ve hata ekranına daha erken düşer.
        let vm = RegisterViewModel(isDemo: true)
        vm.step = .nfc
        vm.nfcRetryMessage = "önceki denemeden kalan uyarı"
        vm.nfcStatus = "okunuyor"

        _ = vm.stepBack()

        XCTAssertNil(vm.nfcRetryMessage)
        XCTAssertEqual(vm.nfcStatus, L.t("nfc_searching"))
    }

    func testSteppingBackKeepsFurthestStepForFeedback() {
        // Vazgeçme geri bildirimi "nerede bıraktı" sorusunu ULAŞILAN EN İLERİ adımla
        // yanıtlar. Geri adım bunu geri sararsa, NFC'de vazgeçen kullanıcı MRZ'de
        // vazgeçmiş gibi raporlanır.
        let vm = RegisterViewModel(isDemo: true)
        vm.step = .mrz
        vm.step = .nfc

        _ = vm.stepBack()

        XCTAssertEqual(vm.furthestFlowStep, .nfc)
    }
}
