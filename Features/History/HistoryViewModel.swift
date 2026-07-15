import Foundation

/// İşlem geçmişi mantığı — Android `HistoryFragment` (yükle, sil tombstone, revoke) portu.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var records: [HistoryRecord] = []
    @Published var busy = false
    @Published var toast: String?
    /// Listede birden fazla farklı (boş olmayan) cihaz adı varsa satırlarda cihaz adı gösterilir.
    @Published var showDevice = false

    private let repo = HistoryRepository.shared

    func load() {
        records = repo.fetchAll(currentCardId: SecureStore.getCardId())
        let distinct = Set(records.map { $0.deviceName.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        showDevice = distinct.count >= 2
    }

    /// Sola kaydır = kaydı sil (tombstone). Android `markAsDeleted`.
    func delete(_ rec: HistoryRecord) {
        guard let id = rec.id else { return }
        repo.markDeleted(id: id)
        load()
    }

    /// Sağa kaydır (SHARED_IDENTITY) = doğrulamayı geri al → POST revoke + revokeTime.
    func revokeVerification(_ rec: HistoryRecord) async {
        guard let id = rec.id, !rec.nonce.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await VerifyAPI.shared.revoke(RevokeRequest(nonce: rec.nonce))
            repo.updateRevokeTime(id: id)
            toast = L.t("revoke_shared_success")
            load()
        } catch {
            // Geri alma = ağ/sunucu çağrısı; geçici hata (kullanıcı tekrar deneyebilir) error değil — tür bazlı seviye.
            Log.failure("Doğrulama geri alma başarısız", error: error, category: .flow)
            toast = L.t("revoke_failed_message")
        }
    }

    /// Sağa kaydır (REGISTRATION) = rıza geri çek + kartı kaldır. Android registration revoke.
    func withdrawRegistration(_ rec: HistoryRecord, appState: AppState) async {
        guard !rec.nonce.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await VerifyAPI.shared.revoke(RevokeRequest(nonce: rec.nonce))
        } catch {
            // Sunucu reddetse bile yerel kaldırma devam eder (Android davranışı toleranslı).
            Log.warning("Kayıt rızası geri çekme sunucu hatası (yerel kaldırma devam): \(error.localizedDescription)", category: .flow)
        }
        let cardId = SecureStore.getCardId()
        TicketStore.clear()
        SecureStore.clear()
        KeychainKeyStore.deleteUserKey()
        repo.insert(
            title: L.t("history_action_revoked"),
            description: L.t("history_desc_revoked"),
            status: 1,
            actionType: .revokedIdentity,
            cardId: cardId ?? ""
        )
        toast = L.t("revoke_registration_success")
        appState.refresh()
        load()
    }
}
