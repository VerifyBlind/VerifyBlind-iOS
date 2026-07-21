import Foundation

/// TCKN'siz kimliklerin yedek anahtarı için PIN zarfını hazırlar.
/// Android `backup/BackupPinPayload.kt` ile BİREBİR (aynı zarf düzeni, aynı JSON alan adları).
///
/// **Neden zarf:** PIN düz metin gönderilseydi relay onu görebilirdi. Relay bu mimaride
/// güvenilmeyen bileşendir (TCKN de aynı sebeple hibrit şifreli geçer) → PIN de kayıt akışındaki
/// kalıpla enclave public key'ine şifrelenir: rastgele AES anahtarı + AES-GCM gövde, anahtar
/// enclave public key'ine RSA-OAEP-SHA256 ile sarılır. Zarfı yalnız enclave açabilir.
///
/// **uuid neden hem içeride hem dışarıda:** içerideki (şifreli) uuid türetimde kullanılır — yakalanan
/// bir zarf başka bir uuid ile eşleştirilip kurbanın PIN'i test edilemesin diye. Dışarıdaki düz metin
/// uuid yalnız sunucunun kota sayacı içindir (sır değildir, yedek dosyasında da düz durur).
///
/// **Sınır:** zarf kaba kuvveti ÇÖZMEZ — yalnız pasif toplamayı keser. Tahmin freni sunucudadır
/// (UUID başına 10/gün + attestation) ve HMAC anahtarı enclave'de olduğu için offline deneme yoktur.
enum BackupPinPayload {

    /// Zarfın içindeki düz metin — yalnız enclave belleğinde çözülür.
    /// Alan adları Android `Inner` ile birebir (`pin`, `uuid`).
    private struct Inner: Codable {
        let pin: String
        let uuid: String
    }

    /// - Parameter enclavePubKey: handshake'ten gelen, attestation ile **doğrulanmış** enclave public
    ///   key'i. Doğrulanmamış bir anahtarla şifrelemek PIN'i saldırgana açar → çağıran taraf taze
    ///   handshake'i garanti etmelidir.
    static func build(pin: String, uuid: String, enclavePubKey: String,
                      integrityToken: String? = nil) throws -> DerivePinRequest {
        let innerData = try JSONEncoder().encode(Inner(pin: pin, uuid: uuid))
        let innerJson = String(decoding: innerData, as: UTF8.self)

        // aesEncrypt: rastgele 256-bit anahtar, blob = nonce(12)‖ciphertext‖tag(16) — .NET
        // CryptoUtils.AesDecrypt'in beklediği düzen (kayıt akışıyla aynı).
        let (blob, aesKey) = try CryptoUtils.aesEncrypt(innerJson)
        // rsaEncrypt = OAEP-SHA256 → enclave'in RsaDecrypt'i (OaepSHA256) ile eşleşir.
        // rsaEncryptForKeystore (OAEP-SHA1) BURADA KULLANILMAZ — o, cihaz Keychain anahtarları içindir.
        let encKey = try CryptoUtils.rsaEncrypt(aesKey, publicKeyBase64: enclavePubKey)

        return DerivePinRequest(encKey: encKey, blob: blob, uuid: uuid, integrityToken: integrityToken)
    }
}
