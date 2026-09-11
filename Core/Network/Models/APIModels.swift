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

    /// En fazla İKİ aday kare (canlı benzerlik akışı). Doluysa enclave `userSelfie` /
    /// `antiSpoofCrop` yerine bunları değerlendirir.
    ///
    /// Sıra: 1 = cihazın en iyi seçtiği kare, 2 = enclave'in canlılık sırasında onayladığı kare
    /// (yalnız 1'den FARKLIYSA eklenir). Enclave her adayı normal kapıdan geçirir ve ilk GEÇEN
    /// kazanır — "önceden onaylanmış" diye bir kavram yoktur.
    ///
    /// Her aday KENDİ selfie'si + KENDİ kırpmasıyla bir bütün olarak değerlendirilir: benzerliği
    /// bir kareden, canlılığı başkasından almak gerçek bir açıktır (Android `Candidates` paritesi).
    var candidates: [RegistrationCandidate]? = nil

    enum CodingKeys: String, CodingKey {
        case candidates = "Candidates"
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
    /// Ölçüm satırlarını canlılık sırasındaki karelerle birleştiren izleme numarası.
    /// Şifreli yükün DIŞINDA: relay'in görmesi gerekir, enclave'in bilmesine gerek yok.
    /// Kimlikle bağ taşımaz.
    var flowId: String? = nil
    /// Adayların cihaz ölçüleri (rank sırasına göre) — canlılık ekranında O KARE için ölçülmüş
    /// değerler. Fotoğrafların KENDİSİ şifreli yükün içinde; relay yalnız sayıları görür ve
    /// onlara güvenmez (aralık kontrolünden geçirir).
    var candidateMetrics: [DeviceFrameMetrics]? = nil

    enum CodingKeys: String, CodingKey {
        case encryptedKey = "encrypted_key"
        case aesBlob = "aes_blob"
        case countryIsoCode = "country_iso_code"
        case flowId = "flow_id"
        case candidateMetrics = "candidate_metrics"
    }
}

/// Final register yükündeki tek aday — kendi selfie'si + kendi 2,7× anti-spoof kırpması.
/// İkisi de AYNI kareden gelmelidir (Android `RegistrationCandidate` paritesi).
struct RegistrationCandidate: Codable {
    var rank: Int
    var userSelfie: String
    var antiSpoofCrop: String

    enum CodingKeys: String, CodingKey {
        case rank = "Rank"
        case userSelfie = "UserSelfie"
        case antiSpoofCrop = "AntiSpoofCrop"
    }
}

/// Girişte tazeliği kanıtlayan tek kare — Android `LoginFaceProof` paritesi.
///
/// ⚠️ LoginRequest gövdesine DÜZ konmaz: `encr_signed_ticket` sarmalının İÇİNE girer
/// (bkz. `LoginWrapperBuilder`) ve enclave public key ile şifrelenir → relay biyometrik
/// görüntüyü GÖRMEZ. Kayıt akışı da selfie'yi aynı sebeple aes_blob içinde taşıyor.
///
/// 🔴 K6: `userSelfie` ve `antiSpoofCrop` AYNI KAREDEN gelmek zorundadır.
struct LoginFaceProof: Codable {
    /// Hizalanmış 112×112 selfie (Base64 PNG).
    let userSelfie: String
    /// AYNI karenin 2,7× geniş anti-spoof kırpması (Base64 JPEG 80×80).
    let antiSpoofCrop: String
    /// Cihaz ölçüleri — DOĞRULANMAZ, yalnız teşhis satırına yazılır.
    let deviceMetrics: DeviceFrameMetrics?

    enum CodingKeys: String, CodingKey {
        case userSelfie = "user_selfie"
        case antiSpoofCrop = "anti_spoof_crop"
        case deviceMetrics = "device_metrics"
    }
}

/// Cihazın kare başına ölçtüğü sinyaller — zaten hesaplanıyorlardı ama hiçbir yere
/// gönderilmiyorlardı.
///
/// ⚠️ Sunucu bu sayılara GÜVENMEZ: aralık kontrolünden geçirir, geçersizse sessizce düşürür.
/// Telemetri asla akışı bozmaz.
struct DeviceFrameMetrics: Codable {
    var deviceMatchScore: Int?
    var luma: Int?
    var sharpness: Int?
    var quality: Int?
    var yaw: Int?
    var pitch: Int?
    var roll: Int?
    var faceWidthRatio: Int?
    var gestureCount: Int?
    var wrongGestureCount: Int?
    var elapsedMs: Int?
    /// Bu gönderimden önce, oran freni (700ms / uçuştaki istek) yüzünden GÖNDERİLMEDEN elenen
    /// iyileşme sayısı. Elenen karenin KENDİSİNİ göndermek veriyi kareyle büyütürdü; bu sayaç,
    /// topladığımız dağılımın ne kadar yanlı olduğunu ölçmenin ucuz yolu.
    var skippedCount: Int?
    /// Yalnız final aday: bu karenin streaming'de gönderildiği `seq`. Hiç gönderilmediyse nil.
    /// İki aday farklı karelerken "hangi kare hangi karara yol açtı" ancak bununla yanıtlanır.
    var sourceSeq: Int?
    var platform: String = "ios"
    var appVersion: String?
    var deviceModel: String?

    enum CodingKeys: String, CodingKey {
        case deviceMatchScore = "device_match_score"
        case luma, sharpness, quality, yaw, pitch, roll
        case faceWidthRatio = "face_width_ratio"
        case gestureCount = "gesture_count"
        case wrongGestureCount = "wrong_gesture_count"
        case elapsedMs = "elapsed_ms"
        case skippedCount = "skipped_count"
        case sourceSeq = "source_seq"
        case platform
        case appVersion = "app_version"
        case deviceModel = "device_model"
    }
}

// MARK: - Canlı benzerlik akışı (streaming)
//
// Amaç: cihazdaki 0.65 kapısında düşen deneme bugün enclave'e HİÇ ulaşmıyor, dolayısıyla kaç
// meşru kullanıcıyı hatalı reddettiğimiz ölçülemiyor. Canlılık sürerken enclave'e kare
// göndermek (a) cihaz skoru düşük kalsa bile enclave onayıyla submit açılmasını, (b) her
// denemenin ölçülebilir bir veri noktasına dönüşmesini sağlar.

/// Akış başı: DG2'nin gömme vektörünü enclave RAM'ine aldırır (şifreli — relay göremez).
struct StreamingPrepareRequest: Codable {
    var flowId: String
    var encryptedKey: String
    var aesBlob: String

    enum CodingKeys: String, CodingKey {
        case flowId = "flow_id"
        case encryptedKey = "encrypted_key"
        case aesBlob = "aes_blob"
    }
}

/// Şifreli prepare yükü — çipten okunan ham DG2.
struct StreamingPreparePayload: Codable {
    var dg2: String

    enum CodingKeys: String, CodingKey {
        case dg2 = "DG2"
    }
}

/// Tek kare: selfie + AYNI karenin 2,7× kırpması.
struct StreamingCheckRequest: Codable {
    var flowId: String
    var encryptedKey: String
    var aesBlob: String
    var seq: Int
    var deviceMetrics: DeviceFrameMetrics?

    enum CodingKeys: String, CodingKey {
        case flowId = "flow_id"
        case encryptedKey = "encrypted_key"
        case aesBlob = "aes_blob"
        case seq
        case deviceMetrics = "device_metrics"
    }
}

/// Şifreli kare yükü — selfie ve kırpma açıkta gitmez.
struct StreamingCheckPayload: Codable {
    var userSelfie: String
    var antiSpoofCrop: String

    enum CodingKeys: String, CodingKey {
        case userSelfie = "UserSelfie"
        case antiSpoofCrop = "AntiSpoofCrop"
    }
}

/// Kare sonucu. İstemci yalnız `similarityPassed` üzerine karar verir; skorlar teşhis içindir.
struct StreamingCheckResponse: Codable {
    var similarityPassed: Bool
    var matchScore: Double?
    var pLive: Double?
    var outcome: String?

    enum CodingKeys: String, CodingKey {
        case similarityPassed = "similarity_passed"
        case matchScore = "match_score"
        case pLive = "p_live"
        case outcome
    }
}

/// Akış bitiş bildirimi.
///
/// 🔴 `flowOutcome` bu işin varlık sebebi olan vakayı görünür kılar: "enclave geçirirdi ama
/// kullanıcı pes etti". Streaming satırları yazılıyordu ama akışın NASIL bittiği hiçbir yerde
/// yoktu.
struct StreamingReleaseRequest: Codable {
    var flowId: String
    /// Sabit küme (sunucu bilinmeyeni düşürür): submitted | abandoned | timeout_gesture |
    /// timeout_session | too_many_errors | match_failed | no_selfie.
    var flowOutcome: String?

    enum CodingKeys: String, CodingKey {
        case flowId = "flow_id"
        case flowOutcome = "flow_outcome"
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
    /// iOS mağaza adresi. `store_url` KASITLI OLARAK YOK: o alan Play adresini taşır ve bu modele
    /// alınırsa zorunlu güncelleme butonu iPhone kullanıcısını Play Store'a atar (eski davranış).
    let storeUrlIos: String?
    let environment: String?
    /// Admin panelden tanımlanır; cihaz sürümü buna eşitse demo butonu görünür (şifre yok).
    let demoVersionIos: String?
    /// Yürürlükteki hukuki metin demeti sürümü. Cihazdaki kabulden yeniyse yeniden onay istenir.
    /// Boş/nil = sunucu bir şey dayatmıyor; istemci gömülü taban sürümünde kalır (bkz. `LegalTerms`).
    let legalTermsVersion: String?
    /// Yapay zekâ asistanı açık mı — GÖRÜNÜRLÜK bilgisi, yetki değil (sunucu kapısı
    /// `ChatbotController`'da). Asistan 2026-08-28'de kapatıldı ve kapalıyken uç 200 + "SSS'ye
    /// bakın" mesajı dönüyor, yani istemci bunu okumazsa kullanıcı hiçbir soruya cevap alamayan
    /// bir asistan görüyor. nil/false → giriş noktası GİZLİ (fail-closed; landing-site de öyle
    /// yapıyor). Bkz. parite denetimi 2026-09-03, O-10.
    let chatbotEnabled: Bool?
    enum CodingKeys: String, CodingKey {
        case minimumAndroidVersion = "minimum_android_version"
        case minimumIosVersion = "minimum_ios_version"
        case storeUrlIos = "store_url_ios"
        case environment
        case demoVersionIos = "demo_version_ios"
        case legalTermsVersion = "legal_terms_version"
        case chatbotEnabled = "chatbot_enabled"
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
