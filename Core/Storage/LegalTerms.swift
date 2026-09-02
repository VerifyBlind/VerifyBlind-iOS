import Foundation

/// Hukuki metin demeti (Kullanım Şartları + Veri İşleme Sözleşmesi + Aydınlatma Metni) kabulü.
/// Android `util/LegalTerms.kt` portu — karar mantığı iki platformda birebir aynıdır.
///
/// Zero-knowledge mimaride kullanıcının sunucuda hesabı YOKTUR (`consent_records` bilinçli olarak
/// user_id/person_id/card_id tutmaz), dolayısıyla "kullanıcı X kabul etti" kaydı sunucuya yazılamaz.
/// Kabulün kanıtı üç ayaklıdır:
///   1. Uygulama kabul alınmadan kullanılamaz (RootView engelleyici overlay).
///   2. Kabul edilen sürüm + zaman damgası cihazda saklanır ve Ayarlar'da gösterilir.
///   3. Yürürlükteki sürüm sunucudan yönetilir (/api/public/app-config → legal_terms_version).
///
/// Sunucu sürümü YALNIZCA yükseltebilir: ayar boş/bozuk/erişilemez olsa bile kapı gömülü
/// `baselineVersion` ile ayakta kalır (fail-open yok) ve hatalı ayar uygulamayı kilitlemez.
enum LegalTerms {

    /// Uygulamaya gömülü taban sürüm — landing-site metinlerinin "Versiyon" etiketiyle hizalı.
    /// Sunucuya hiç ulaşılamadığında geçerli olan alt sınırdır.
    static let baselineVersion = "1.0"

    // MARK: - Saf karar mantığı

    /// Yürürlükteki sürüm: sunucu değeri yalnızca daha yeniyse geçerlidir.
    static func requiredVersion(serverVersion: String?, baseline: String = baselineVersion) -> String {
        let server = serverVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !server.isEmpty, parse(server) != nil else { return baseline }
        return compare(server, baseline) > 0 ? server : baseline
    }

    /// Kabul yoksa, bozuksa veya gerekliden eskiyse yeniden onay gerekir (fail-closed).
    static func needsAcceptance(acceptedVersion: String?, requiredVersion: String) -> Bool {
        let accepted = acceptedVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accepted.isEmpty, parse(accepted) != nil else { return true }
        return compare(accepted, requiredVersion) < 0
    }

    // MARK: - Cihaz kaydı

    static var acceptedVersion: String? {
        get { UserDefaults.standard.string(forKey: "legal_terms_accepted_version") }
        set { UserDefaults.standard.set(newValue, forKey: "legal_terms_accepted_version") }
    }

    static var acceptedAt: Date? {
        let seconds = UserDefaults.standard.double(forKey: "legal_terms_accepted_at")
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Kabulü kalıcılaştırır. Sürüm + zaman damgası birlikte yazılır; kanıt ikisidir.
    static func recordAcceptance(version: String) {
        UserDefaults.standard.set(version, forKey: "legal_terms_accepted_version")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "legal_terms_accepted_at")
    }

    /// Kabul kaydını siler — tam temizlikte (`DataWipe.wipeAll`) çağrılır.
    ///
    /// Kabul kaydı bir KANIT: sürüm + zaman damgası taşıyor ve Ayarlar'da gösteriliyor. Tam temizlik
    /// kullanıcıya ait her izi sildiği hâlde bu kayıt kalırsa cihaz, artık var olmayan bir kullanıcı
    /// adına "şu sürümü şu tarihte kabul etti" demeye devam eder — telefon el değiştirdiyse bu iddia
    /// yanlıştır. Android tarafı `user_prefs`'i tümüyle sildiği için bu kaydı da götürüyor; burada
    /// `AppPrefs.clearAll()` sayılı anahtarları sildiğinden kayıt sağ kalıyordu.
    static func clearAcceptance() {
        UserDefaults.standard.removeObject(forKey: "legal_terms_accepted_version")
        UserDefaults.standard.removeObject(forKey: "legal_terms_accepted_at")
    }

    /// Ayarlar ekranı için "1.0 · 27 Tem 2026" özeti; kabul yoksa nil.
    static var acceptanceSummary: String? {
        guard let version = acceptedVersion, !version.isEmpty else { return nil }
        guard let at = acceptedAt else { return version }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(version) · \(formatter.string(from: at))"
    }

    static func needsAcceptance(serverVersion: String? = nil) -> Bool {
        needsAcceptance(acceptedVersion: acceptedVersion,
                        requiredVersion: requiredVersion(serverVersion: serverVersion))
    }

    // MARK: - Sürüm karşılaştırma

    /// "1.10" > "1.9" olacak şekilde parça parça sayısal karşılaştırma.
    private static func compare(_ a: String, _ b: String) -> Int {
        guard let left = parse(a) else { return -1 }
        guard let right = parse(b) else { return 1 }
        for i in 0..<Swift.max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Yalnızca nokta ile ayrılmış sayılar kabul edilir; aksi halde nil (bozuk sürüm).
    private static func parse(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }
}
