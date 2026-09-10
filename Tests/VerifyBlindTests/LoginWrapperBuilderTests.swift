import XCTest
@testable import VerifyBlind

/// Girişteki canlı yüz kapısının iOS tarafı.
///
/// Neyi koruyor: girişte kişiyi kanıtlayan tek şey cihaz kilidiydi ve cihaz kilidi PIN/parola ile de
/// açılıyor — telefonu açabilen biri kart sahibi adına doğrulanabiliyordu. Kapı, kayıt anında bilete
/// mühürlenen yüz referansını giriş anındaki canlı kareyle karşılaştırarak bunu kapatır.
///
/// Bu testler iki sözleşmeyi sabitler:
///   1. Kamera adımının açılıp açılmayacağı kararı (fail-closed, enclave kuralıyla birebir).
///   2. Karenin ŞİFRELİ sarmalın içinde taşınması — düz gitseydi relay selfie'yi görürdü.
final class LoginWrapperBuilderTests: XCTestCase {

    private func ticket(tckn: String, faceRef: String) -> String {
        """
        {"Payload":{"TCKN":"\(tckn)","UserPubKey":"pk","FaceRefJpegB64":"\(faceRef)"},"Signature":"sig"}
        """
    }

    // MARK: - needsLiveFace: kamera adımı açılsın mı

    func testFaceRefPresentRequiresLiveFace() {
        XCTAssertTrue(LoginWrapperBuilder.needsLiveFace(
            signedTicketJson: ticket(tckn: "10000000146", faceRef: "ZmFjZS1yZWY=")))
    }

    func testEmptyFaceRefSkipsLiveFace() {
        // Demo bileti: DemoRegisterAsync gerçek çip görmediği için FaceRefJpegB64'ü hiç set etmez →
        // referans YAPISAL olarak boştur ve atlama yolu kendiliğinden çalışır. UI test pilotunun
        // turları bu sayede kamerayı hiç görmeden geçer.
        XCTAssertFalse(LoginWrapperBuilder.needsLiveFace(
            signedTicketJson: ticket(tckn: "00000000000", faceRef: "")))
    }

    func testUnreadableTicketRequiresLiveFace() {
        // 🔴 FAIL-CLOSED BEKÇİSİ. Bileti okuyamadığımızda kamerayı AÇMAK zorundayız: sessizce
        // atlamak, kapıyı hiç eklememekle aynı şey olurdu. Biri burayı "okunamıyorsa atla" diye
        // değiştirirse bu test kırılmalı.
        XCTAssertTrue(LoginWrapperBuilder.needsLiveFace(signedTicketJson: "not json at all"))
        XCTAssertTrue(LoginWrapperBuilder.needsLiveFace(signedTicketJson: "{}"))
    }

    func testDecisionIgnoresTcknWhenReferenceExists() {
        // Karar YALNIZ referansa bakar, TCKN'ye değil. Demo sentinel'i taşıyan ama referansı DOLU
        // bir bilet (bugün üretilmiyor) yine de kamera açmalı — enclave de öyle davranır.
        XCTAssertTrue(LoginWrapperBuilder.needsLiveFace(
            signedTicketJson: ticket(tckn: "00000000000", faceRef: "ZmFjZS1yZWY=")))
    }

    // MARK: - build: kare şifreli sarmalın İÇİNDE

    func testFaceProofIsEmbeddedInsideWrapper() throws {
        let proof = LoginFaceProof(userSelfie: "c2VsZmll", antiSpoofCrop: "Y3JvcA==", deviceMetrics: nil)
        let json = try LoginWrapperBuilder.build(
            signedTicketJson: ticket(tckn: "10000000146", faceRef: "ZmFjZS1yZWY="),
            nonce: "nonce-1", pkHash: "hash-1", faceProof: proof)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(root["signed_ticket"])
        XCTAssertEqual(root["nonce"] as? String, "nonce-1")
        XCTAssertEqual(root["pk_hash"] as? String, "hash-1")

        // Enclave bu anahtarları bu adlarla okur (snake_case) — isim değişirse kapı sessizce
        // "kare gelmedi" görür ve giriş reddedilir.
        let faceProof = try XCTUnwrap(root["face_proof"] as? [String: Any])
        XCTAssertEqual(faceProof["user_selfie"] as? String, "c2VsZmll")
        XCTAssertEqual(faceProof["anti_spoof_crop"] as? String, "Y3JvcA==")
    }

    func testWrapperOmitsFaceProofWhenNotProvided() throws {
        // Demo yolu: kare yok → anahtar HİÇ yazılmamalı (boş nesne değil). Enclave "face_proof
        // yok" ile "face_proof boş" arasında ayrım yapmıyor ama sözleşmeyi net tutuyoruz.
        let json = try LoginWrapperBuilder.build(
            signedTicketJson: ticket(tckn: "00000000000", faceRef: ""),
            nonce: "nonce-1", pkHash: nil)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(root["face_proof"])
        XCTAssertNil(root["pk_hash"])
    }

    func testTicketIsEmbeddedRawSoSealedFieldsSurvive() throws {
        // Bilet RAW gömülür: typed round-trip yapılsaydı modelde OLMAYAN alanlar (SignedAtUnix,
        // FaceRefJpegB64) DÜŞER ve enclave MAC'i yeniden hesaplarken imza uyuşmazdı → her giriş patlar.
        let json = try LoginWrapperBuilder.build(
            signedTicketJson: ticket(tckn: "10000000146", faceRef: "ZmFjZS1yZWY="),
            nonce: "n", pkHash: nil)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let ticketObj = try XCTUnwrap(root["signed_ticket"] as? [String: Any])
        let payload = try XCTUnwrap(ticketObj["Payload"] as? [String: Any])
        XCTAssertEqual(payload["FaceRefJpegB64"] as? String, "ZmFjZS1yZWY=")
    }
}
