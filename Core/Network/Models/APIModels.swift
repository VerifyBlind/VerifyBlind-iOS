import Foundation

/// Android `api/ApiModels.kt` → Swift `Codable` portu.
///
/// Wire anahtarları Android `@SerializedName` (snake_case) ve PascalCase (SecurePayload,
/// SignedTicket, TicketPayload — Gson alan adını aynen kullanır) ile **birebir** eşleşmeli.
/// Bu yüzden global `convertFromSnakeCase` KULLANILMAZ; her tipte explicit `CodingKeys`.
///
/// Aşama 1'de yalnızca `AppConfigResponse` ve `HandshakeResponse` self-test'te kullanılır;
/// geri kalanı Android `api/` paketinin tam sözleşme portudur (Aşama 4 register/login için hazır).

// MARK: - Handshake

struct HandshakeRequest: Codable {
    var integrityToken: String = ""
    var fcmToken: String? = nil
    var platform: String? = "ios"

    enum CodingKeys: String, CodingKey {
        case integrityToken = "integrity_token"
        case fcmToken = "fcm_token"
        case platform
    }
}

struct HandshakeResponse: Codable {
    let nonce: String
    let timestamp: Int64
    let nonceSignature: String
    let pcr0Signature: String?
    let attestationDocument: String?
    let enclavePubKey: String?
    let challenges: [Int]?

    enum CodingKeys: String, CodingKey {
        case nonce
        case timestamp
        case nonceSignature = "nonce_signature"
        case pcr0Signature = "pcr0_signature"
        case attestationDocument = "attestation_document"
        case enclavePubKey = "enclave_pub_key"
        case challenges
    }
}

struct LoginHandshakeResponse: Codable {
    let attestationDocument: String?
    let pcr0Signature: String?
    let enclavePubKey: String?

    enum CodingKeys: String, CodingKey {
        case attestationDocument = "attestation_document"
        case pcr0Signature = "pcr0_signature"
        case enclavePubKey = "enclave_pub_key"
    }
}

// MARK: - Register

/// NFC + biyometri düz metin payload'ı (hybrid RSA+AES ile şifrelenip gönderilir).
/// Wire anahtarları PascalCase (Gson alan adlarını aynen kullanıyor).
struct SecurePayload: Codable {
    var sod: String
    var dg1: String
    /// RAW DG2 EF bytes (Base64) — SOD hash binding for the face data group AND biometric face source:
    /// the enclave extracts the face from this verified DG2 (Dg2FaceExtractor); it is no longer sent
    /// separately. Enclave `VerifyDGHashes` requires this. (Security review Y-3.)
    var dg2: String = ""
    var dg15: String = ""
    var activeSig: String
    var aaChallenge: String = ""
    var userPubKey: String
    var nonce: String = ""
    var timestamp: Int64 = 0
    var nonceSignature: String = ""
    // NOT: Kimlik yüz fotoğrafı ayrı GÖNDERİLMEZ — enclave biyometrik yüzü SOD-doğrulanmış ham DG2'den
    // çıkarır (Dg2FaceExtractor). Eski dg2Photo alanı belgeye bağlı olmayan görüntüye güvendiği için kaldırıldı.
    var livenessVideo: String = ""
    var zoomVideo: String = ""
    var userSelfie: String = ""
    var integrityToken: String = ""
    /// 2.7x geniş yüz crop, 80x80 JPEG Base64 — enclave MiniFASNetV2 pasif liveness (Android `AntiSpoofCrop` paritesi).
    var antiSpoofCrop: String = ""

    enum CodingKeys: String, CodingKey {
        case sod = "SOD"
        case dg1 = "DG1"
        case dg2 = "DG2"
        case dg15 = "DG15"
        case activeSig = "ActiveSig"
        case aaChallenge = "AAChallenge"
        case userPubKey = "UserPubKey"
        case nonce = "Nonce"
        case timestamp = "Timestamp"
        case nonceSignature = "NonceSignature"
        case livenessVideo = "LivenessVideo"
        case zoomVideo = "ZoomVideo"
        case userSelfie = "UserSelfie"
        case integrityToken = "IntegrityToken"
        case antiSpoofCrop = "AntiSpoofCrop"
    }
}

struct RegistrationRequest: Codable {
    var encryptedKey: String
    var aesBlob: String
    var countryIsoCode: String = ""

    enum CodingKeys: String, CodingKey {
        case encryptedKey = "encrypted_key"
        case aesBlob = "aes_blob"
        case countryIsoCode = "country_iso_code"
    }
}

struct DemoRegisterRequest: Codable {
    var userPubKey: String
    var appVersion: String = ""
    /// Relay sürüm kontrolünü App Store'a yönlendirir (Play Store değil).
    var platform: String = "ios"

    enum CodingKeys: String, CodingKey {
        case userPubKey = "user_pub_key"
        case appVersion = "app_version"
        case platform
    }
}

struct EncryptedTicketResponse: Codable {
    /// JSON *string* — içinde stringlenmiş `HybridContent` (`{enc_key, blob}`).
    let encryptedTicket: String
    let registrationNonce: String?

    enum CodingKeys: String, CodingKey {
        case encryptedTicket = "encrypted_ticket"
        case registrationNonce = "registration_nonce"
    }

    init(encryptedTicket: String, registrationNonce: String?) {
        self.encryptedTicket = encryptedTicket
        self.registrationNonce = registrationNonce
    }

    /// Toleranslı decode: `encrypted_ticket` string VEYA obje olabilir; obje ise tekrar string'e
    /// çevrilir (sonra HybridContent parse edilir). Gson leniency paritesi.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .encryptedTicket) {
            encryptedTicket = s
        } else if let obj = try? c.decode(JSONValue.self, forKey: .encryptedTicket) {
            let data = try JSONEncoder().encode(obj)
            encryptedTicket = String(decoding: data, as: UTF8.self)
        } else {
            encryptedTicket = ""
        }
        registrationNonce = try c.decodeIfPresent(String.self, forKey: .registrationNonce)
    }
}

/// Hybrid zarf: RSA ile şifreli AES key + AES-GCM blob.
struct HybridContent: Codable {
    let encKey: String
    let blob: String

    enum CodingKeys: String, CodingKey {
        case encKey = "enc_key"
        case blob
    }
}

/// Register dönüşünde çözülen birleşik payload (Android `UnifiedRegistrationPayload`).
/// `ticket` alt-nesnesi RAW JSON olarak yeniden saklanır (typed round-trip ile alan kaybı riski yok) —
/// login sarmalı bu raw ticket'i aynen gömer, imza geçerli kalır.
struct UnifiedRegistrationPayload: Codable {
    let ticket: SignedTicket
    var personId: String = ""
    var cardId: String = ""

    enum CodingKeys: String, CodingKey {
        case ticket
        case personId = "person_id"
        case cardId = "card_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try c.decode(SignedTicket.self, forKey: .ticket)
        personId = try c.decodeIfPresent(String.self, forKey: .personId) ?? ""
        cardId = try c.decodeIfPresent(String.self, forKey: .cardId) ?? ""
    }
}

// MARK: - Ticket (PascalCase wire keys)

struct SignedTicket: Codable {
    let payload: TicketPayload
    let signature: String

    enum CodingKeys: String, CodingKey {
        case payload = "Payload"
        case signature = "Signature"
    }
}

/// ⚠️ Gson (Android) eksik/null alanları sessizce default'a düşürür; Swift `Codable` STRICT — eksik
/// non-optional anahtar `keyNotFound` fırlatır. Bu yüzden custom `init(from:)` ile TÜM alanlar
/// `decodeIfPresent ?? ""` (Gson paritesi) — server bazı alanları (DogumTarihi, vb.) atlayabilir.
struct TicketPayload: Codable {
    var tckn: String = ""
    var ad: String = ""
    var soyad: String = ""
    var dogumTarihi: String = ""
    var seriNo: String = ""
    var gecerlilikTarihi: String = ""
    var cinsiyet: String = ""
    var uyruk: String = ""
    var userPubKey: String = ""
    var countryIsoCode: String = ""
    var personId: String = ""
    var cardId: String = ""
    var documentType: String? = nil

    enum CodingKeys: String, CodingKey {
        case tckn = "TCKN"
        case ad = "Ad"
        case soyad = "Soyad"
        case dogumTarihi = "DogumTarihi"
        case seriNo = "SeriNo"
        case gecerlilikTarihi = "GecerlilikTarihi"
        case cinsiyet = "Cinsiyet"
        case uyruk = "Uyruk"
        case userPubKey = "UserPubKey"
        case countryIsoCode = "CountryIsoCode"
        case personId = "PersonId"
        case cardId = "CardId"
        case documentType = "DocumentType"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tckn = try c.decodeIfPresent(String.self, forKey: .tckn) ?? ""
        ad = try c.decodeIfPresent(String.self, forKey: .ad) ?? ""
        soyad = try c.decodeIfPresent(String.self, forKey: .soyad) ?? ""
        dogumTarihi = try c.decodeIfPresent(String.self, forKey: .dogumTarihi) ?? ""
        seriNo = try c.decodeIfPresent(String.self, forKey: .seriNo) ?? ""
        gecerlilikTarihi = try c.decodeIfPresent(String.self, forKey: .gecerlilikTarihi) ?? ""
        cinsiyet = try c.decodeIfPresent(String.self, forKey: .cinsiyet) ?? ""
        uyruk = try c.decodeIfPresent(String.self, forKey: .uyruk) ?? ""
        userPubKey = try c.decodeIfPresent(String.self, forKey: .userPubKey) ?? ""
        countryIsoCode = try c.decodeIfPresent(String.self, forKey: .countryIsoCode) ?? ""
        personId = try c.decodeIfPresent(String.self, forKey: .personId) ?? ""
        cardId = try c.decodeIfPresent(String.self, forKey: .cardId) ?? ""
        documentType = try c.decodeIfPresent(String.self, forKey: .documentType)
    }
}

// MARK: - Login

struct LoginRequest: Codable {
    var encrSignedTicket: String
    var nonce: String
    var integrityToken: String = ""
    // Holder-of-key (Y-4): "VBLOK1|{nonce}|{pk_hash}|{user_sig_ts}" mesajının user key (RSA-PSS/SHA-256) imzası
    var userSignature: String = ""
    var userSigTs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case encrSignedTicket = "encr_signed_ticket"
        case nonce
        case integrityToken = "integrity_token"
        case userSignature = "user_signature"
        case userSigTs = "user_sig_ts"
    }
}

// LoginResponse KALDIRILDI: relay /login mobile'a daima `{}` döner (encrypted_response partner
// callback'ine gider, app'e değil). `VerifyAPI.login` artık postNoContent (Void) — decode yok.

// MARK: - Partner / PoP

struct PartnerInfoResponse: Codable {
    let partnerId: String
    let name: String
    let logoUrl: String
    let logoBase64: String?
    let description: String?
    let scopes: [String]?
    let validations: JSONValue?
    /// App-to-app deeplink "geri dönüş" için partner'ın kayıtlı return şeması (ör. "verifyblinddemo").
    /// nil/boş → app-return kapalı; deeplink'teki return URL'i AÇILMAZ (fail-closed).
    let appReturnScheme: String?

    enum CodingKeys: String, CodingKey {
        case partnerId = "partner_id"
        case name
        case logoUrl = "logo_url"
        case logoBase64 = "logo_base64"
        case description
        case scopes
        case validations
        case appReturnScheme = "app_return_scheme"
    }
}

struct PopCancelRequest: Codable {
    var nonce: String
    var reason: String? = nil
}

// MARK: - Revoke

struct RevokeRequest: Codable {
    var nonce: String
    var integrityToken: String = ""

    enum CodingKeys: String, CodingKey {
        case nonce
        case integrityToken = "integrity_token"
    }
}

struct RevokeResponse: Codable {
    let message: String?
    let error: String?
}

// MARK: - App config

struct AppConfigResponse: Codable {
    let minimumAndroidVersion: String?
    let minimumIosVersion: String?
    let storeUrl: String?
    let environment: String?
    /// Admin panelden tanımlanır; cihaz sürümü buna eşitse demo butonu görünür (şifre yok).
    let demoVersionIos: String?
    /// Bulut yedek YAZMA formatı. false → v1 (eski), true → v2 (KEK/DEK).
    /// Varsayılan false: sunucu bu alanı henüz döndürmüyorsa v1 yazılır (güvenli taraf).
    /// Sunucu tarafında ancak v1+v2 OKUYAN sürüme zorunlu güncelleme bitince açılır — eski istemci
    /// bir v2 dosyasını `wraps` alanını düşürerek geri yazar ve DEK kalıcı olarak kaybolur.
    let backupFormatV2: Bool?

    enum CodingKeys: String, CodingKey {
        case minimumAndroidVersion = "minimum_android_version"
        case minimumIosVersion = "minimum_ios_version"
        case storeUrl = "store_url"
        case environment
        case demoVersionIos = "demo_version_ios"
        case backupFormatV2 = "backup_format_v2"
    }
}

// MARK: - Backup PIN (TCKN'siz kimlikler)

/// PIN + UUID → person_id (KEK = SHA256(person_id) ile sarılı DEK'i açar). Android `DerivePinRequest`
/// paritesi. UUID sır değil — per-user salt.
struct DerivePinRequest: Codable {
    let pin: String
    let uuid: String
    /// iOS'ta App Attest header'dan gider; body'de null bırakılır (Android Play Integrity token'ı koyar).
    var integrityToken: String?

    enum CodingKeys: String, CodingKey {
        case pin, uuid
        case integrityToken = "integrity_token"
    }
}

struct DerivePinResponse: Codable {
    let personId: String

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
    }
}

// MARK: - KVKK

struct KvkkWithdrawRequest: Codable {
    var nonce: String
    var reason: String? = "Kullanıcı talebi"
}

struct KvkkBlockCardRequest: Codable {
    var nonce: String
    var cardId: String? = nil
    var reason: String? = "USER_REQUEST"

    enum CodingKeys: String, CodingKey {
        case nonce
        case cardId = "card_id"
        case reason
    }
}

// MARK: - Privacy notice (KVKK aydınlatma metni)

/// `GET /api/kvkk/privacy-notice?format=text` → `{ version, effectiveDate, language, text }`.
struct PrivacyNoticeResponse: Codable {
    let text: String?
    let version: String?
    let language: String?
}

// MARK: - App Attest (Aşama 6)

/// `GET /api/Verify/appattest/challenge` → `{ challenge }` (base64 rastgele, tek-kullanımlık, Redis TTL).
struct AppAttestChallengeResponse: Codable {
    let challenge: String
}

/// `POST /api/Verify/appattest/enroll` gövdesi — attestation + challenge ile anahtar kaydı.
struct AppAttestEnrollRequest: Codable {
    let keyId: String
    let attestation: String   // base64 CBOR attestation object
    let challenge: String
}

/// Korunan isteklerin `X-App-Attest` başlığı (JSON → base64). Assertion belirli bir challenge'a bağlı.
struct AppAttestToken: Codable {
    let keyId: String
    let challenge: String
    let assertion: String     // base64 CBOR assertion
}

// MARK: - Error body

/// Sunucu hata gövdesi (`{error, code, details}`) — Android `ApiError`/`parseApiError` eşdeğeri.
/// `errorCode`: login akışında enclave'in döndürdüğü top-level `error_code` (ör. ERR_TICKET_REVOKED).
struct APIErrorBody: Codable {
    let error: String?
    let code: String?
    let details: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case error, code, details
        case errorCode = "error_code"
    }
}

// MARK: - JSONValue (keyfi JSON taşıyıcı — örn. PartnerInfoResponse.validations)

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Desteklenmeyen JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }
}
