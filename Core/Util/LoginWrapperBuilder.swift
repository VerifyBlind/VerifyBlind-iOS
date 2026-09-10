import Foundation

/// Login sarmalı kurucu — Android `MainViewModel.completeLogin` wrapper'ı:
/// `{"signed_ticket": <ticket obj>, "nonce": "...", "pk_hash"?: "...", "face_proof"?: {...}}`.
/// Ticket RAW JSON olarak gömülür (typed round-trip yapılmaz → imza alanları korunur).
///
/// ⚠️ Bu sarmal AES ile şifrelenip anahtarı enclave public key ile sarılır. Canlı yüz karesi
/// bu yüzden BURAYA konur, LoginRequest gövdesine değil: düz gitseydi relay kullanıcının
/// selfie'sini görürdü (kayıt akışı da biyometriyi aynı sebeple aes_blob içinde taşıyor).
/// Yan fayda: kare bu login'in nonce'una bağlanmış olur.
enum LoginWrapperBuilder {
    static func build(signedTicketJson: String, nonce: String, pkHash: String?,
                      faceProof: LoginFaceProof? = nil) throws -> String {
        let ticketObj = try JSONSerialization.jsonObject(with: Data(signedTicketJson.utf8))
        var wrapper: [String: Any] = ["signed_ticket": ticketObj, "nonce": nonce]
        if let pkHash, !pkHash.isEmpty { wrapper["pk_hash"] = pkHash }
        if let faceProof {
            let encoded = try JSONEncoder().encode(faceProof)
            wrapper["face_proof"] = try JSONSerialization.jsonObject(with: encoded)
        }
        let data = try JSONSerialization.data(withJSONObject: wrapper, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    /// Bu bilet giriş için canlı yüz karesi ister mi?
    ///
    /// Karar biletin İÇİNDEKİ `FaceRefJpegB64`'e bakar — enclave'in kuralının BİREBİR aynısı
    /// (bkz. `EnforceLoginFaceProof`) ve Android `ticketNeedsLiveFace` ile aynı alan. İki taraf
    /// aynı mühürlü olguya baktığı için sapamazlar.
    ///
    /// ⚠️ Demo BUTONUNUN sürüm kapısına (`demo_version_ios`) ASLA bakma: o yalnız yapılandırmadır
    /// ve zayıftır — 2026-09-03'te iOS'ta yanlışlıkla tüm kullanıcılara açık bulundu. Demo
    /// biletlerin referansı YAPISAL olarak boştur (DemoRegisterAsync gerçek çip görmez), yani
    /// atlama yolu kendiliğinden çalışır.
    /// Bilete mühürlü yüz referansı (Base64 JPEG) — giriş ekranındaki % göstergesi için.
    /// Android `MainViewModel.ticketFaceRef` paritesi. Referans cihazdan DIŞARI çıkmaz.
    static func faceRef(signedTicketJson: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(signedTicketJson.utf8)),
              let root = obj as? [String: Any],
              let payload = root["Payload"] as? [String: Any],
              let ref = payload["FaceRefJpegB64"] as? String, !ref.isEmpty else { return nil }
        return ref
    }

    static func needsLiveFace(signedTicketJson: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(signedTicketJson.utf8)),
              let root = obj as? [String: Any],
              let payload = root["Payload"] as? [String: Any] else {
            // Bileti okuyamadıysak kamerayı AÇ (fail-closed). Referanssız bir bilet zaten enclave
            // tarafından reddedilir; sessizce atlamak kapıyı hiç eklememekle aynı şey olurdu.
            Log.warning("Bilet yüz referansı okunamadı — canlı yüz adımı zorunlu sayıldı", category: .flow)
            return true
        }
        let faceRef = payload["FaceRefJpegB64"] as? String
        return !(faceRef ?? "").isEmpty
    }
}
