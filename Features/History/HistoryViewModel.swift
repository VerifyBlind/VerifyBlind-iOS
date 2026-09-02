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

    /// Sola kaydır = kaydı SERT sil. Android `HistoryFragment` → `repository.deleteById`. Tombstone
    /// YOK: satır kalırsa nonce'u yedekten geri yüklemeyi kalıcı olarak bloklar. Onay diyaloğu
    /// çağıranda (`HistoryView`), Android'deki `delete_record_title` diyaloğuyla aynı.
    func delete(_ rec: HistoryRecord) {
        guard let id = rec.id else { return }
        repo.deleteById(id)
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

    /// Sağa kaydır (REGISTRATION) = rıza geri çek + kartı kaldır. Android `HistoryFragment`
    /// registration revoke paritesi:
    ///
    /// 1. Sunucu KABUL ETMEDEN yerel durum DEĞİŞMEZ. (Eskiden iOS hatayı yutup kartı yine de
    ///    kaldırıyordu — "Android toleranslı" notu yanlıştı; kullanıcı kartı kaybederken rıza
    ///    sunucuda kayıtlı kalabiliyordu.)
    /// 2. Kabul edilirse MEVCUT kayda `revokeTime` yazılır ("Rıza Geri Çekildi" olarak görünür);
    ///    yeni bir geçmiş kaydı EKLENMEZ. (`HistoryAction.revokedIdentity` yalnız eski kayıtları
    ///    göstermek için duruyor — Android'de de tanımlı ama hiç yazılmıyor.)
    /// 3. 404 + `REVOKE_NOT_FOUND` başarı sayılır: sunucuda silinecek consent kaydı olmayan eski
    ///    kayıtlar için yalnız yerel temizlik yapılır.
    ///
    /// Not: kart kalktıktan sonra `fetchAll` filtresi (Android paritesi) cardId'li kayıtları gizler,
    /// yani işaretlenen satır listeden çıkar — kayıt DB'de durur ve yedeğe girer.
    func withdrawRegistration(_ rec: HistoryRecord, appState: AppState) async {
        guard let id = rec.id, !rec.nonce.isEmpty else { return }
        busy = true; defer { busy = false }
        // Kart burada gerçekten gidiyor (+ Keychain anahtarı siliniyor) → sahibi doğrulasın.
        // Ekrana girişteki kapı bir kez geçilince tek dokunuşla kimlik kaybına yol açıyordu;
        // cüzdandan silme zaten biyometrik istiyor, aynı yıkıcılıktaki bu yol da istemeli
        // (Android `HistoryFragment` registration-revoke paritesi).
        do {
            try await BiometricGate.authenticate(reason: L.t("biometric_subtitle_decrypt"))
        } catch {
            // İptal beklenen kullanıcı davranışı → event değil, breadcrumb.
            Log.info("Rıza geri çekme biyometrik iptal", category: .flow)
            return
        }
        do {
            _ = try await VerifyAPI.shared.revoke(RevokeRequest(nonce: rec.nonce))
        } catch APIClientError.http(let status, let body) where status == 404 && body?.code == "REVOKE_NOT_FOUND" {
            Log.info("Rıza geri çekme: sunucuda consent kaydı yok (REVOKE_NOT_FOUND) → yalnız yerel temizlik", category: .flow)
        } catch {
            Log.failure("Kayıt rızası geri çekme başarısız (yerel durum korundu)", error: error, category: .flow)
            toast = L.t("revoke_failed_message")
            return
        }
        repo.updateRevokeTime(id: id)
        TicketStore.clear()
        SecureStore.clear()
        KeychainKeyStore.deleteUserKey()
        toast = L.t("revoke_registration_success")
        appState.refresh()
        load()
    }
}
