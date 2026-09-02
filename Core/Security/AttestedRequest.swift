import Foundation

/// Sıra bekletmeli async kilit.
///
/// ⚠️ Actor izolasyonu bu iş için YETMEZ. Swift actor'ları `await` noktalarında yeniden
/// girilebilir: bir çağrı ağı beklerken ikincisi actor'a girer. `AppAttestService` zaten bir
/// actor'dı ve yarış yine de yaşandı.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()   // kilidi doğrudan devret
        }
    }
}

/// App Attest ile korunan çağrıları TEK SIRA hâlinde yürütür.
///
/// NEDEN: App Attest sayacı her imzada artıyor ve sunucu KESİN ARTAN sıra bekliyor
/// (`counter <= keyRow.SignCount` → red). İki korumalı istek aynı anda uçarsa imzalar ağda
/// sırasız varıyor ve geride kalan "sayaç gerilemesi (replay)" ile reddediliyor. Cihazda
/// 2026-08-26'da görüldü: aynı saniyede iki challenge, biri OK (count=13), diğeri RED.
/// Replay edilmiş bir şey yoktu — yalnızca iki meşru istek yarışmıştı.
///
/// Kilit, imza üretimini VE isteği birlikte kapsar. Yalnız üretimi sıralamak yetmezdi: sıra
/// asıl ağ gönderiminde bozuluyor.
///
/// Sunucudaki sayaç kontrolünü gevşetmek de bir seçenekti (challenge'lar zaten tek kullanımlık,
/// yani replay koruması esasen orada). Onun yerine bu yol seçildi: bir güvenlik katmanını
/// inceltmektense sorunu kaynağında çözmek, katmanı olduğu gibi bırakır.
enum AttestedRequest {

    private static let lock = AsyncLock()

    /// Başlıkları üretir ve isteği kilit altında yürütür.
    /// - Parameter cardId: verilirse assertion bu card_id'ye bağlanır (bkz. `attestationHeaders`).
    static func perform<T>(boundTo cardId: String? = nil,
                           _ body: (_ headers: [String: String]) async throws -> T) async throws -> T {
        await lock.acquire()
        do {
            let headers = await AppAttestService.shared.attestationHeaders(boundTo: cardId)
            let result = try await body(headers)
            await lock.release()
            return result
        } catch {
            await lock.release()
            throw error
        }
    }
}
