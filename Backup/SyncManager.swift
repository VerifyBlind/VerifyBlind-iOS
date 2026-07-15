import Foundation

/// Çift yönlü bulut senkron sonucu (Android `SyncManager.SyncResult`).
struct SyncResult {
    var itemsAdded = 0
    var itemsDeleted = 0
    var itemsUploaded = 0
    var error: String?
    var skipped = false

    var isSuccess: Bool { error == nil && !skipped }
    var hasChanges: Bool { itemsAdded > 0 || itemsDeleted > 0 || itemsUploaded > 0 }
}

/// Çift yönlü bulut senkron — Android `backup/SyncManager.kt` portu (birebir).
/// Akış: indir → çöz → yerele eksikleri ekle → bulutta olmayan gönderilmişleri (tombstone) → hepsini
/// `personId`-AES-GCM ile şifreleyip yükle. Çözülemeyen (başka kimliğe ait) öğeler aynen korunur.
///
/// Güvenlik kuralları (Android paritesi): indirme BAŞARISIZSA hiçbir şey silme; bulut dosyası YOKSA
/// "her şey silindi" SAYMA (yereli koru, dosyayı yeniden oluştur). Şifreleme çapraz platform
/// uyumlu ([[project_ios_backup_zkp_hardening]]). `actor` → eşzamanlı çağrılar "skipped" döner.
actor SyncManager {
    static let shared = SyncManager()

    private let filename = "verifyblind_backup.json"
    private var isSyncing = false
    private let repo = HistoryRepository.shared

    func performSync(provider: CloudProvider) async -> SyncResult {
        guard !isSyncing else {
            Log.info("Eşitleme zaten sürüyor, atlanıyor", category: .flow)
            return SyncResult(skipped: true)
        }
        isSyncing = true
        defer { isSyncing = false }

        guard provider.isLoggedIn() else { return SyncResult(error: "Bulut bağlantısı yok") }

        // Yereldeki personId'ler (bulut öğelerini çözmek için anahtarlar). Telefon sıfırlanıp kart
        // yeniden eklenirse aynı personId türetilir → o kişinin kayıtları yeniden çözülebilir.
        let localItems = repo.getAllHistorySnapshot()
        let localPersonIds = Array(Set(localItems.map { $0.personId }.filter { !$0.isEmpty }))

        // ===== PHASE 1: indir =====
        let json: String?
        do {
            json = try await provider.download(filename: filename)
        } catch {
            // İndirme başarısız → bulutun gerçek halini bilmiyoruz, yereli koru, çık.
            Log.info("Bulut yedek indirilemedi, eşitleme iptal (yerel korunuyor)", category: .flow)
            return SyncResult(error: "Bulut yedek indirilemedi: \(error)")
        }
        let cloudFileExists = (json != nil)

        var cloudItemsDecrypted: [HistoryRecord] = []
        var cloudNonces = Set<String>()
        // Yerel anahtarlarla çözülemeyen (başka kimliğe ait) öğeler — yüklemede aynen geri yazılır.
        var foreignCloudItems: [CloudHistoryItem] = []
        // Aynı koruma partnerler için: yerel anahtarla çözülemeyen şifreli partner girdileri.
        var foreignPartnerEntries: [EncPartner] = []

        if let json, let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CloudPayload.self, from: data) {
            // Partnerleri çöz: her şifreli girdiyi yerel personId'lerle dene; çözüleni keep-newer
            // (lastUpdated) ile birleştir, çözülemeyeni (başka kimliğe ait) aynen koru.
            for entry in payload.partnersEnc ?? [] {
                var decrypted: BackupPartnerItem?
                for pid in localPersonIds {
                    guard let jsonStr = try? CryptoUtils.aesGcmDecrypt(ciphertextBase64: entry.enc, ivBase64: entry.iv, personId: pid),
                          let obj = try? JSONDecoder().decode(BackupPartnerItem.self, from: Data(jsonStr.utf8)) else { continue }
                    decrypted = obj
                    break
                }
                if let p = decrypted, !p.id.isEmpty {
                    let local = PartnerManager.get(p.id)
                    if local == nil || p.lastUpdated > local!.timestamp {
                        PartnerManager.save(p.toPartnerItem())
                    }
                } else {
                    foreignPartnerEntries.append(entry)   // başka kimliğin partneri → koru
                }
            }
            for raw in payload.history ?? [] {
                var decrypted: InnerPayload?
                for pid in localPersonIds {
                    guard let jsonStr = try? CryptoUtils.aesGcmDecrypt(ciphertextBase64: raw.enc, ivBase64: raw.iv, personId: pid),
                          let obj = try? JSONDecoder().decode(InnerPayload.self, from: Data(jsonStr.utf8)),
                          obj.personId == pid else { continue }
                    decrypted = obj
                    break
                }
                if let d = decrypted {
                    let rec = HistoryRecord(
                        id: nil, title: d.title, description: d.description,
                        actionType: raw.actionType, status: raw.status, timestamp: d.timestamp,
                        transactionId: raw.transactionId, nonce: d.nonce, personId: d.personId,
                        cardId: d.cardId, partnerId: d.partnerId, deviceName: d.deviceName ?? "",
                        isSent: true, isDeleted: false, revokeTime: nil
                    )
                    cloudItemsDecrypted.append(rec)
                    cloudNonces.insert(d.nonce)
                } else {
                    foreignCloudItems.append(raw)   // başka kimliğin kaydı → koru
                }
            }
        }

        let localNonces = repo.getAllNonces()
        let deletedNonces = repo.getDeletedNonces()
        var itemsAdded = 0, itemsDeleted = 0, itemsUploaded = 0

        // ===== PHASE 2: yerele eksikleri ekle =====
        for cloudItem in cloudItemsDecrypted
        where !localNonces.contains(cloudItem.nonce) && !deletedNonces.contains(cloudItem.nonce) {
            repo.insertCloudItem(cloudItem)
            itemsAdded += 1
        }

        // ===== PHASE 3: bulutta olmayan gönderilmiş yerel öğeleri sil =====
        // SADECE bulutta gerçek bir yedek dosyası VARSA (yoksa yanlışlıkla tüm yereli silme).
        if cloudFileExists {
            for sent in repo.getSentItems() where !cloudNonces.contains(sent.nonce) {
                repo.markDeletedByNonce(sent.nonce)
                itemsDeleted += 1
            }
        }

        // ===== PHASE 4: yükle =====
        let allLocal = repo.getAllHistorySnapshot()   // çözülmüş, silinmemiş
        var uploadList: [CloudHistoryItem] = []
        var unsentNonces: [String] = []
        for item in allLocal where !item.personId.isEmpty {
            let inner = InnerPayload(
                title: item.title, description: item.description, cardId: item.cardId,
                personId: item.personId, timestamp: item.timestamp, nonce: item.nonce, partnerId: item.partnerId,
                // item, getAllHistorySnapshot'tan gelir → deviceName çözülmüş (orijin cihaz adı).
                deviceName: item.deviceName.isEmpty ? nil : item.deviceName
            )
            guard let innerData = try? JSONEncoder().encode(inner),
                  let innerJson = String(data: innerData, encoding: .utf8),
                  let pair = try? CryptoUtils.aesGcmEncrypt(innerJson, personId: item.personId) else {
                Log.error("Eşitleme: öğe şifrelenemedi (\(item.nonce))", category: .flow)
                continue
            }
            uploadList.append(CloudHistoryItem(enc: pair.ciphertext, iv: pair.iv,
                                               actionType: item.actionType, status: item.status,
                                               transactionId: item.transactionId))
            if !item.isSent { unsentNonces.append(item.nonce) }
        }
        // Başka kimliğe ait öğeleri aynen koru (üzerine yazıp yok etme).
        uploadList.append(contentsOf: foreignCloudItems)

        // Silinmiş (tombstone) nonce'ları "gönderildi işaretlenecek" listesine ekle.
        for item in repo.getUnsentItems() where item.isDeleted && !unsentNonces.contains(item.nonce) {
            unsentNonces.append(item.nonce)
        }

        let needsUpload = !unsentNonces.isEmpty || itemsDeleted > 0 || itemsAdded > 0
            || (!cloudFileExists && !uploadList.isEmpty)
        if needsUpload {
            // Partnerleri şifrele: her partner, geçmişte onu İLK referans veren personId ile şifrelenir.
            // Cache'te olmayan ya da hiçbir geçmiş öğesinin referans vermediği (orphan) partner
            // yedeklenmez — re-fetch edilebilir. Çözülemeyen foreign girdiler aynen korunur.
            var partnerOwner: [String: String] = [:]   // partnerId -> personId (ilk sahip)
            for item in allLocal {
                if let pid = item.partnerId, !pid.isEmpty, !item.personId.isEmpty, partnerOwner[pid] == nil {
                    partnerOwner[pid] = item.personId
                }
            }
            var partnersEnc: [EncPartner] = []
            for (partnerId, personId) in partnerOwner {
                guard let local = PartnerManager.get(partnerId) else { continue }
                let backupItem = BackupPartnerItem(from: local)
                guard let pData = try? JSONEncoder().encode(backupItem),
                      let pJson = String(data: pData, encoding: .utf8),
                      let pair = try? CryptoUtils.aesGcmEncrypt(pJson, personId: personId) else {
                    Log.error("Eşitleme: partner şifrelenemedi (\(partnerId))", category: .flow)
                    continue
                }
                partnersEnc.append(EncPartner(enc: pair.ciphertext, iv: pair.iv))
            }
            partnersEnc.append(contentsOf: foreignPartnerEntries)

            let cloudPayload = CloudPayload(history: uploadList, partnersEnc: partnersEnc.isEmpty ? nil : partnersEnc)
            guard let payloadData = try? JSONEncoder().encode(cloudPayload),
                  let payloadJson = String(data: payloadData, encoding: .utf8) else {
                return SyncResult(itemsAdded: itemsAdded, itemsDeleted: itemsDeleted, error: "Yük serileştirilemedi")
            }
            do {
                try await provider.upload(filename: filename, data: payloadJson)
                repo.markAsSent(unsentNonces)
                repo.cleanupSyncedTombstones()
                itemsUploaded = unsentNonces.count
                Log.info("Eşitleme: yükleme başarılı, \(itemsUploaded) öğe gönderildi", category: .flow)
            } catch {
                return SyncResult(itemsAdded: itemsAdded, itemsDeleted: itemsDeleted, error: "Yükleme başarısız: \(error)")
            }
        }

        CloudBackupManager.saveLastBackupTimestamp()
        return SyncResult(itemsAdded: itemsAdded, itemsDeleted: itemsDeleted, itemsUploaded: itemsUploaded)
    }
}
