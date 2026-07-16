import Foundation
import CryptoKit

/// Cihaz attestation'ını isteğin hassas payload'ına (card_id) kriptografik olarak bağlar.
///
/// App Attest assertion'ı "gerçek cihaz + gerçek app + taze challenge" kanıtlar ama istek gövdesini
/// imzalamaz. TLS pinning kaldırıldığından (Cloudflare/OWASP kararı — [[project_cloudflare_edge_cert_pinning]])
/// araya giren biri gövdedeki card_id'yi imzadan sonra değiştirebilir. card_id'yi clientDataHash'e
/// katınca assertion yalnız bu tam card_id için geçerli olur.
///
/// Sözleşme — sunucu (VerifyBlind.API/Services/AttestationBinding.cs) ve Android
/// (util/AttestationBinding.kt) ile BİREBİR aynı:
///   bind = SHA256( UTF8( fresh + "\n" + cardId ) )      (32 byte)
///   iOS clientDataHash = bind (ham)   ·   Android requestHash = Base64(bind)
/// "fresh": iOS'ta App Attest challenge, Android'de akış nonce'u (ikisi de tek-kullanımlık).
///
/// Golden vector üç tarafta aynı: Stage6SelfTest ↔ AttestationBindingTests.cs ↔ AttestationBindingTest.kt.
/// Ayraç/kodlama değişirse ÜÇÜ birden değişmeli; aksi halde block-card sunucuda sessizce RED alır.
enum AttestationBinding {

    /// Ayraç — fresh ile cardId arasında. Değiştirmek golden vector'ü kırar.
    static let separator = "\n"

    /// bind = SHA256( UTF8( fresh + "\n" + cardId ) ) → 32 byte.
    static func bindHash(fresh: String, cardId: String) -> Data {
        Data(SHA256.hash(data: Data((fresh + separator + cardId).utf8)))
    }

    /// App Attest assertion'ının imzalayacağı clientDataHash (ham 32 byte).
    static func clientDataHash(challenge: String, cardId: String) -> Data {
        bindHash(fresh: challenge, cardId: cardId)
    }

    /// Base64 temsili — Android requestHash ile aynı değer; golden-vector çapraz kontrolü için.
    static func requestHashBase64(fresh: String, cardId: String) -> String {
        bindHash(fresh: fresh, cardId: cardId).base64EncodedString()
    }
}
