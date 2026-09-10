import XCTest
@testable import VerifyBlind

/// Attestation yeniden-deneme politikasının sözleşmesi.
///
/// Regresyon (`VERIFYBLIND-IOS-46`, 2026-08-31 / 09-10, üç kez): enclave belgesindeki leaf
/// sertifika 3 saat ömürlü ve AWS onu ancak vadesine ~15 dk kala döndürüyor. O pencereye denk
/// gelen açılış, sunucu tamamen sağlıklıyken (relay aynı belgeyi 200 ile geçiriyordu) süresi
/// dolmuş bir zincir görüp uygulamayı bloke ediyordu. "Yeniden Dene"ye basmak düzeltiyordu —
/// yani kurtarma zaten çalışıyordu, yalnızca ELLE tetikleniyordu.
///
/// Burada sınanan şey, yeniden denemenin DOĞRU TÜRDE çalıştığı: geçici olabilen `.integrity`
/// denenir, deploy boşluğunu gösteren `.authorization` denenmez. İkisini karıştırmak iki ayrı
/// hataya yol açar — birincisinde kullanıcı kendi kendine düzelecek bir hatayı görür,
/// ikincisinde saniyeler içinde düzelmeyecek bir hata için boşuna bekletilir.
final class AttestationRetryPolicyTests: XCTestCase {

    func testIntegrityIsRetriedUntilTheLimit() {
        for attempt in 0..<HandshakeService.integrityRetryCount {
            XCTAssertTrue(
                HandshakeService.shouldRetry(kind: .integrity, attempt: attempt),
                "Geçici olabilen integrity hatası \(attempt). denemede yeniden denenmeli — "
                + "AWS sertifika rotasyon penceresi saniyeler içinde kapanıyor"
            )
        }
    }

    func testIntegrityStopsAtTheLimitSoTheBlockStillHappens() {
        // FAIL-CLOSED KORUNUYOR: yeniden denemeler tükendiğinde blok geri geliyor.
        // Bu olmazsa kapı sonsuza kadar denerdi ve gerçek bir kurcalama hiç bildirilmezdi.
        XCTAssertFalse(
            HandshakeService.shouldRetry(kind: .integrity, attempt: HandshakeService.integrityRetryCount),
            "Deneme hakkı bitince bloklanmalı — fail-closed davranış korunmalı"
        )
    }

    func testAuthorizationIsNeverRetried() {
        // PCR0 imzası eksik/eşleşmiyorsa sebep bir deploy boşluğudur (pcr0_signatures.json
        // yeniden imzalanmamış). Bekleyerek düzelmez; kullanıcıyı oyalamak yerine hemen söyle.
        for attempt in 0...HandshakeService.integrityRetryCount {
            XCTAssertFalse(
                HandshakeService.shouldRetry(kind: .authorization, attempt: attempt),
                "PCR0 yetkilendirme hatası yeniden denenmemeli (deploy boşluğu, kendiliğinden düzelmez)"
            )
        }
    }
}
