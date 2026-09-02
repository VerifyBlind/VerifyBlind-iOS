import Foundation

/// Aşama 5 (Backup) deterministik doğrulaması — manuel `.vfbackup` modeli. Cihazda dev env
/// butonuyla koşar; CI'da KOŞMAZ.
///
/// Çapraz-platform sözleşme: RFC 7914 PBKDF2/AES-GCM golden vektörleri (Android `BackupCryptoTest`
/// ile AYNI) + zarf (encrypt/plaintext) round-trip + içerik sızmazlığı. Drift olursa bir platformda
/// alınan yedek diğerinde ÇÖZÜLEMEZ. `SelfTestResult`/`check` Stage1'de tanımlı.
enum Stage5SelfTest {

    static func runAll() -> [SelfTestResult] {
        var r: [SelfTestResult] = []

        let sample = [
            BackupRecord(nonce: "nonce-1", personId: "person-A", cardId: "card-1", partnerId: "Acme",
                         title: "Doğrulama Tamamlandı", description: "Partner: Acme", actionType: 2,
                         status: 1, timestamp: 1_700_000_000_000, transactionId: nil, deviceName: "iPhone")
        ]

        // ── GOLDEN: PBKDF2/AES-GCM RFC 7914 vektörleri (Android BackupCryptoTest paritesi) ──
        r.append(check("GOLDEN: PBKDF2/AES-GCM çapraz-platform vektörleri") {
            if let err = BackupCrypto.selfTestGoldenVectors() { return (false, err) }
            return (true, "ok")
        })

        // ── Şifreli zarf round-trip (write→read) ──
        r.append(check("Şifreli .vfbackup round-trip") {
            let json = try BackupFile.write(records: sample, password: "correct horse battery")
            let back = try BackupFile.read(json: json, password: "correct horse battery")
            return (back == sample, back == sample ? "ok" : "round-trip uyuşmadı")
        })

        // ── Şifreli dosya düz metin içeriği sızdırmamalı ──
        r.append(check("Şifreli dosya düz metin sızdırmaz") {
            let json = try BackupFile.write(records: sample, password: "pw123456")
            let ok = !json.contains("nonce-1") && !json.contains("person-A") && !json.contains("Acme")
            return (ok, ok ? "ok" : "sızıntı!")
        })

        // ── Yanlış parola reddi ──
        r.append(check("Yanlış parola reddedilir") {
            let json = try BackupFile.write(records: sample, password: "right")
            do {
                _ = try BackupFile.read(json: json, password: "wrong")
                return (false, "yanlış parola çözdü!")
            } catch {
                return (true, "reddedildi")
            }
        })

        // ── Şifresiz zarf round-trip + inspect ──
        r.append(check("Şifresiz .vfbackup round-trip + inspect") {
            let json = try BackupFile.write(records: sample, password: nil)
            let info = try BackupFile.inspect(json: json)
            let back = try BackupFile.read(json: json, password: nil)
            let ok = !info.encrypted && info.recordCount == 1 && back == sample
            return (ok, ok ? "ok" : "şifresiz round-trip uyuşmadı")
        })

        // ── İçe-aktarma tekilleştirmesi: aynı nonce ATLANIR ──
        r.append(check("selectNewRecords aynı nonce'u atlar") {
            let selected = BackupMapper.selectNewRecords(sample, localNonces: ["nonce-1"])
            return (selected.isEmpty, selected.isEmpty ? "atlandı" : "tekrar eklendi!")
        })

        // ── Dosya adı iki nokta içermez (SAF/paylaşım) ──
        r.append(check("Dosya adı ':' içermez") {
            let name = BackupNaming.defaultFileName()
            let ok = !name.contains(":") && name.hasSuffix(".vfbackup")
            return (ok, name)
        })

        return r
    }

    private static func check(_ name: String, _ body: () throws -> (Bool, String)) -> SelfTestResult {
        do {
            let (passed, detail) = try body()
            return SelfTestResult(name: name, passed: passed, detail: detail)
        } catch {
            return SelfTestResult(name: name, passed: false, detail: "throw: \(error)")
        }
    }
}
