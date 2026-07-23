import Foundation
import Security

/// `.vfbackup` dosyasının serileştirilmesi/ayrıştırılması — Android `backup/BackupFile.kt` portu.
/// Kanonik sözleşme: `docs/superpowers/specs/2026-07-23-manual-backup-restore-design.md`.
///
/// İki zarf biçimi:
///  - **Şifresiz:** `encryption` yok/null, `records` düz dizi.
///  - **Şifreli:** `encryption` = {cipher,kdf,iterations,salt,iv}, `payload` = base64(ciphertext‖tag);
///    `records` yazılmaz (içerik sızmaz).
///
/// Android tarafı `encryption`'ı açık `null` yazar; iOS omit eder — İKİ TARAF DA "yok VEYA null"u
/// şifresiz sayar, o yüzden çapraz-okuma sorunsuzdur. İç düz metin, iki biçimde de aynı `records`
/// dizisidir. Base64 = standart dolgulu (Android `java.util.Base64` ile aynı).
enum BackupFile {

    static let schemaVersion = 1
    static let iterations = 600_000
    private static let cipher = "AES-256-GCM"
    private static let kdf = "PBKDF2-HMAC-SHA256"
    private static let saltBytes = 16

    private struct EncryptionMeta: Codable {
        let cipher: String
        let kdf: String
        let iterations: Int
        let salt: String
        let iv: String
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let app: String
        let createdAt: String
        let fileId: String
        let encryption: EncryptionMeta?   // nil → şifresiz (omit)
        let records: [BackupRecord]?
        let payload: String?
    }

    /// Yeni yedek üretir. `password == nil` → şifresiz dosya.
    static func write(records: [BackupRecord], password: String?) throws -> String {
        let created = ISO8601DateFormatter().string(from: Date())
        let fileId = UUID().uuidString

        let env: Envelope
        if let pw = password {
            let salt = randomBytes(saltBytes)
            let key = BackupCrypto.deriveKey(password: pw, salt: salt, iterations: iterations)
            let inner = try JSONEncoder().encode(records)
            let (iv, ct) = try BackupCrypto.encrypt(plaintext: inner, key: key)
            env = Envelope(
                schemaVersion: schemaVersion, app: "VerifyBlind", createdAt: created, fileId: fileId,
                encryption: EncryptionMeta(cipher: cipher, kdf: kdf, iterations: iterations,
                                           salt: salt.base64EncodedString(), iv: iv.base64EncodedString()),
                records: nil, payload: ct.base64EncodedString()
            )
        } else {
            env = Envelope(
                schemaVersion: schemaVersion, app: "VerifyBlind", createdAt: created, fileId: fileId,
                encryption: nil, records: records, payload: nil
            )
        }
        let data = try JSONEncoder().encode(env)
        return String(decoding: data, as: UTF8.self)
    }

    /// Dosyayı ayrıştırıp kayıtları döner. Şifreli dosyada `password` gerekir; yanlış/eksik parola
    /// `BackupPasswordError` fırlatır. Tekilleştirme çağıranın işidir.
    static func read(json: String, password: String?) throws -> [BackupRecord] {
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        } catch {
            throw BackupPasswordError.malformed
        }

        guard let enc = env.encryption else {
            return env.records ?? []
        }
        guard let pw = password else { throw BackupPasswordError.needsPassword }
        guard let salt = Data(base64Encoded: enc.salt),
              let iv = Data(base64Encoded: enc.iv),
              let payload = env.payload, let ct = Data(base64Encoded: payload) else {
            throw BackupPasswordError.malformed
        }
        let key = BackupCrypto.deriveKey(password: pw, salt: salt, iterations: enc.iterations)
        let plain: Data
        do {
            plain = try BackupCrypto.decrypt(iv: iv, ciphertextWithTag: ct, key: key)
        } catch {
            throw BackupPasswordError.wrongPassword
        }
        do {
            return try JSONDecoder().decode([BackupRecord].self, from: plain)
        } catch {
            throw BackupPasswordError.malformed
        }
    }

    /// Dosyayı DB'ye eklemeden meta bilgisini okur. Şifreli dosyada sayı paroladan önce bilinemez → nil.
    static func inspect(json: String) throws -> BackupInfo {
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        } catch {
            throw BackupPasswordError.malformed
        }
        let encrypted = env.encryption != nil
        return BackupInfo(
            schemaVersion: env.schemaVersion, fileId: env.fileId, createdAt: env.createdAt,
            encrypted: encrypted, recordCount: encrypted ? nil : (env.records?.count ?? 0)
        )
    }

    private static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, n, ptr.baseAddress!)
        }
        return d
    }
}
