import XCTest
import GRDB
@testable import VerifyBlind

/// `fetchAll(currentCardId:)` görünürlük filtresi — Android `HistoryFragment` ile BİREBİR olmalı:
/// `item.cardId.isEmpty() || item.cardId == (currentCardId ?: "")`.
///
/// Kritik nokta kayıtlı kart YOKKEN (nil) ne olduğudur: iOS eskiden bu durumda TÜM kayıtları
/// gösteriyordu (kaldırılan kartın geçmişi ekranda kalıyordu), Android ise yalnız cardId'si boş
/// genel kayıtları gösterir. Kayıtlar silinmez — yalnız gizlenir ve yedeğe girmeye devam eder.
final class HistoryCardFilterTests: XCTestCase {

    private func makeRepo() throws -> (AppDatabase, HistoryRepository) {
        let appDb = try AppDatabase(DatabaseQueue())
        return (appDb, HistoryRepository(db: appDb.dbQueue))
    }

    private func insertRaw(_ dbQueue: DatabaseQueue, nonce: String, cardId: String) throws {
        var rec = HistoryRecord(
            id: nil, title: "t", description: "d",
            actionType: HistoryAction.registration.rawValue, status: 1,
            timestamp: 1_700_000_000_000, transactionId: nil, nonce: nonce,
            personId: "p1", cardId: cardId, partnerId: nil, deviceName: "",
            isSent: false, isDeleted: false, revokeTime: nil
        )
        try dbQueue.write { db in try rec.insert(db) }
    }

    func testOnlyCurrentCardAndGenericRecordsAreVisible() throws {
        let (appDb, repo) = try makeRepo()
        try insertRaw(appDb.dbQueue, nonce: "AIT", cardId: "card-A")
        try insertRaw(appDb.dbQueue, nonce: "BASKA", cardId: "card-B")
        try insertRaw(appDb.dbQueue, nonce: "GENEL", cardId: "")

        let visible = Set(repo.fetchAll(currentCardId: "card-A").map(\.nonce))
        XCTAssertEqual(visible, ["AIT", "GENEL"], "Başka karta ait kayıt gizlenmeli")
    }

    func testNoRegisteredCardHidesCardBoundRecords() throws {
        let (appDb, repo) = try makeRepo()
        try insertRaw(appDb.dbQueue, nonce: "AIT", cardId: "card-A")
        try insertRaw(appDb.dbQueue, nonce: "GENEL", cardId: "")

        let visible = repo.fetchAll(currentCardId: nil).map(\.nonce)
        XCTAssertEqual(visible, ["GENEL"], "Kart kayıtlı değilken cardId'li kayıtlar GİZLENMELİ (Android paritesi)")
    }

    /// Gizlenen kayıt hâlâ yedeklenebilir olmalı: snapshot cardId filtresi UYGULAMAZ.
    func testHiddenRecordsStillGoIntoBackupSnapshot() throws {
        let (appDb, repo) = try makeRepo()
        try insertRaw(appDb.dbQueue, nonce: "AIT", cardId: "card-A")
        try insertRaw(appDb.dbQueue, nonce: "GENEL", cardId: "")

        XCTAssertTrue(repo.fetchAll(currentCardId: nil).map(\.nonce) == ["GENEL"])
        XCTAssertEqual(Set(repo.getAllHistorySnapshot().map(\.nonce)), ["AIT", "GENEL"],
                       "Gizli kayıt yedek anlık görüntüsünde YER ALMALI")
    }
}
