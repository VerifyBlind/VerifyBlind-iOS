import Foundation

/// `HistoryRecord` (ÇÖZÜLMÜŞ) ↔ `BackupRecord` eşlemesi ve içe-aktarma tekilleştirmesi.
/// Android `backup/BackupMapper.kt` portu. Bu katman kimlik/kripto TAŞIMAZ; şifreleme repository'de.
enum BackupMapper {

    static func toRecord(_ e: HistoryRecord) -> BackupRecord {
        BackupRecord(
            nonce: e.nonce, personId: e.personId, cardId: e.cardId, partnerId: e.partnerId,
            title: e.title, description: e.description, actionType: e.actionType, status: e.status,
            timestamp: e.timestamp, transactionId: e.transactionId, deviceName: e.deviceName
        )
    }

    /// Düz metin `HistoryRecord` üretir (id=nil → autogenerate). Şifreleme repository'de yapılır.
    static func toEntity(_ r: BackupRecord) -> HistoryRecord {
        HistoryRecord(
            id: nil, title: r.title, description: r.description, actionType: r.actionType,
            status: r.status, timestamp: r.timestamp, transactionId: r.transactionId, nonce: r.nonce,
            personId: r.personId, cardId: r.cardId, partnerId: r.partnerId, deviceName: r.deviceName,
            isSent: false, isDeleted: false, revokeTime: nil
        )
    }

    /// Additive + idempotent: yerelde var olan nonce'lar ATLANIR, yalnız yeniler döner.
    static func selectNewRecords(_ incoming: [BackupRecord], localNonces: Set<String>) -> [BackupRecord] {
        incoming.filter { !localNonces.contains($0.nonce) }
    }
}

/// Manuel Yedekle/Geri Yükle orkestrasyonu — Android `backup/BackupManager.kt` portu.
enum BackupManager {

    struct ImportResult { let added: Int; let skipped: Int }

    /// Yedeklenecek kayıtlar: yerel geçmişin çözülmüş anlık görüntüsü → `BackupRecord` listesi.
    static func collectRecords(_ repo: HistoryRepository = .shared) -> [BackupRecord] {
        repo.getAllHistorySnapshot().map { BackupMapper.toRecord($0) }
    }

    /// Additive + idempotent içe aktarma: yerelde OLMAYAN nonce'lar (yeniden şifrelenerek) eklenir.
    static func importRecords(_ repo: HistoryRepository = .shared, _ incoming: [BackupRecord]) -> ImportResult {
        let localNonces = repo.getAllNonces()
        let toAdd = BackupMapper.selectNewRecords(incoming, localNonces: localNonces)
        for r in toAdd { repo.insertBackupRecord(r) }
        return ImportResult(added: toAdd.count, skipped: incoming.count - toAdd.count)
    }
}
