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
/// şifreleyip yükle. Çözülemeyen (başka kimliğe ait) öğeler aynen korunur.
///
/// Şifreleme iki formatı destekler:
///   v1 (eski): geçmiş DOĞRUDAN `SHA256(personId)` ile şifreli.
///   v2 (yeni): geçmiş rastgele DEK ile şifreli; DEK, KEK=`SHA256(personId)` ile sarılıp dosyadaki
///              `wraps[]` içinde tutulur (bkz. `BackupFormat`).
/// OKUMA her zaman iki formatı da destekler. YAZMA sunucu bayrağına bağlıdır
/// (`AppConfigCache.isBackupFormatV2Enabled`) — bayrak ancak zorunlu güncelleme bitince açılır.
///
/// Güvenlik kuralları (Android paritesi): indirme BAŞARISIZSA hiçbir şey silme; bulut dosyası YOKSA
/// "her şey silindi" SAYMA (yereli koru, dosyayı yeniden oluştur). Şifreleme çapraz platform
/// uyumlu ([[project_ios_backup_zkp_hardening]]). `actor` → eşzamanlı çağrılar "skipped" döner.
actor SyncManager {
    static let shared = SyncManager()

    private let filename = "verifyblind_backup.json"
    private var isSyncing = false
    private let repo = HistoryRepository.shared

    /// Yüklenecek bloğu doğru formatla şifreler: `dek` varsa v2 (ham anahtar), yoksa v1 (personId).
    /// Ayrı fonksiyon: guard-let içinde `try?`'li ternary Swift'te kırılgan ve okunmaz.
    private func encryptForUpload(_ json: String, dek: Data?, personId: String) -> (ciphertext: String, iv: String)? {
        if let dek {
            return try? CryptoUtils.aesGcmEncryptRaw(json, key: dek)
        }
        return try? CryptoUtils.aesGcmEncrypt(json, personId: personId)
    }

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

        // Senkron boyunca kullanılacak DEK'ler (yalnız v2'de dolu).
        var activeDeks: [Data] = []
        // Yerel anahtarlarla AÇILAMAYAN wrap'ler (başka kimliğe ait) — yüklemede AYNEN geri yazılır,
        // yoksa o kimliğin DEK'i kalıcı olarak kaybolur.
        var foreignWraps: [DekWrap] = []
        var cloudIsV2 = false

        if let json, let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CloudPayload.self, from: data) {
            cloudIsV2 = BackupFormat.isV2(payload)

            if cloudIsV2 {
                let allWraps = payload.wraps ?? []
                activeDeks = BackupFormat.unwrapDeks(allWraps, personIds: localPersonIds)
                for w in allWraps where BackupFormat.unwrapDeks([w], personIds: localPersonIds).isEmpty {
                    foreignWraps.append(w)
                }
                // Açılan DEK'i yerel önbelleğe al — BULUT OTORİTEDİR: buradaki eski kopya (varsa)
                // üzerine yazılır, böylece iki cihaz bağımsız DEK ürettiyse yakınsar.
                if let dek = activeDeks.first, let pid = localPersonIds.first {
                    SecureStore.saveDek(personId: pid, dekB64: dek.base64EncodedString())
                }
                Log.info("Bulut yedek v2: \(activeDeks.count) DEK açıldı, \(foreignWraps.count) yabancı wrap korunuyor", category: .flow)
            } else {
                Log.info("Bulut yedek v1 (eski format) — personId ile doğrudan çözülecek", category: .flow)
            }

            // Partnerleri çöz: çözüleni keep-newer (lastUpdated) ile birleştir,
            // çözülemeyeni (başka kimliğe ait) aynen koru.
            for entry in payload.partnersEnc ?? [] {
                var decrypted: BackupPartnerItem?
                if let jsonStr = BackupFormat.tryDecrypt(enc: entry.enc, iv: entry.iv, isV2: cloudIsV2,
                                                         deks: activeDeks, personIds: localPersonIds),
                   let obj = try? JSONDecoder().decode(BackupPartnerItem.self, from: Data(jsonStr.utf8)) {
                    decrypted = obj
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
                if let jsonStr = BackupFormat.tryDecrypt(enc: raw.enc, iv: raw.iv, isV2: cloudIsV2,
                                                         deks: activeDeks, personIds: localPersonIds),
                   let obj = try? JSONDecoder().decode(InnerPayload.self, from: Data(jsonStr.utf8)),
                   // v1'de anahtar personId'den türediği için bu eşleşme ek doğrulamaydı. v2'de DEK
                   // kimlikten bağımsız → personId'yi bilinenler arasında AYRICA doğrula ki başka
                   // kimliğin öğesi yanlışlıkla benimsenmesin.
                   !obj.personId.isEmpty, localPersonIds.contains(obj.personId) {
                    decrypted = obj
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

        // YAZMA formatı SUNUCU bayrağıyla kontrol edilir. Eski (v1-only) bir istemci v2 dosyasını
        // `wraps` alanını DÜŞÜREREK geri yazar → DEK sonsuza dek kaybolur ve tüm geçmiş kurtarılamaz.
        // Bu yüzden v2 yazma ancak zorunlu güncelleme bitince açılır.
        let writeV2 = AppConfigCache.isBackupFormatV2Enabled()

        // v2 yazacaksak DEK gerekli. Öncelik: (1) buluttan açılan (OTORİTE — iki cihaz bağımsız DEK
        // ürettiyse buna yakınsar), (2) yerel önbellek, (3) yeni üret (ilk yedek).
        // Wrap'i BURADA, öğeleri şifrelemeden ÖNCE üret. Sonra üretmek tehlikeli: sarma başarısız
        // olursa öğeler DEK ile şifrelenmiş ama başlık v1 yazılmış olur → yedek okunamaz. Sarma
        // başarısızsa DEK'i düşürüp tümüyle v1'e dönmek tek tutarlı davranış.
        var writeDek: Data?
        var outWraps: [DekWrap]?
        if writeV2, let pid = localPersonIds.first {
            let candidate: Data
            if let d = activeDeks.first {
                candidate = d
            } else if let cached = SecureStore.getDek(personId: pid), let d = Data(base64Encoded: cached) {
                candidate = d
            } else {
                candidate = CryptoUtils.generateDek()
                Log.info("Yeni DEK üretildi (bulutta açılabilir wrap yok)", category: .flow)
            }

            if let mine = try? BackupFormat.wrapDek(candidate, personId: pid,
                                                    pinUuid: SecureStore.getPinUuid(personId: pid)) {
                writeDek = candidate
                outWraps = [mine] + foreignWraps
                SecureStore.saveDek(personId: pid, dekB64: candidate.base64EncodedString())
            } else {
                // Sarılamayan DEK'le v2 yazılamaz; v1'e düş (writeDek nil kalır → öğeler personId ile).
                Log.error("DEK sarılamadı — bu senkron v1 formatında yazılacak", category: .flow)
            }
        }

        for item in allLocal where !item.personId.isEmpty {
            let inner = InnerPayload(
                title: item.title, description: item.description, cardId: item.cardId,
                personId: item.personId, timestamp: item.timestamp, nonce: item.nonce, partnerId: item.partnerId,
                // item, getAllHistorySnapshot'tan gelir → deviceName çözülmüş (orijin cihaz adı).
                deviceName: item.deviceName.isEmpty ? nil : item.deviceName
            )
            guard let innerData = try? JSONEncoder().encode(inner),
                  let innerJson = String(data: innerData, encoding: .utf8),
                  let pair = encryptForUpload(innerJson, dek: writeDek, personId: item.personId) else {
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
                      let pair = encryptForUpload(pJson, dek: writeDek, personId: personId) else {
                    Log.error("Eşitleme: partner şifrelenemedi (\(partnerId))", category: .flow)
                    continue
                }
                partnersEnc.append(EncPartner(enc: pair.ciphertext, iv: pair.iv))
            }
            partnersEnc.append(contentsOf: foreignPartnerEntries)

            // outWraps yukarıda, öğeler şifrelenmeden ÖNCE üretildi → başlık ile öğe şifrelemesi
            // her zaman tutarlı. v1 yazarken v/wraps nil → JSONEncoder bunları ATLAR → çıktı
            // birebir eski v1 şeması olur (eski istemcilerle uyum).
            let cloudPayload = CloudPayload(
                v: outWraps != nil ? BackupFormat.versionV2 : nil,
                wraps: outWraps,
                history: uploadList,
                partnersEnc: partnersEnc.isEmpty ? nil : partnersEnc)
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
