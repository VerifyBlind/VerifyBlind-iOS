import Foundation

/// Kart ekleme akışı yarıda kalınca "bir sorun mu yaşadınız?" sorma kararı.
///
/// İki kural:
///  • Yalnız HATA sonrası sorulur, sıradan vazgeçişte değil. Telefonu çaldığı için çıkan kullanıcıya
///    destek kutusu göstermek gereksiz gürültüdür.
///  • Sıklık sınırlı (bkz. `interval`). Aynı olaydan doğan ikinci tetik yutulur; aksi halde
///    uygulama kullanıcıyı suçluyormuş gibi hissettirir.
///
/// Karar tamamen CİHAZDA verilir — sunucuda "şu kullanıcıya soruldu mu" diye bir kayıt tutulmaz.
enum FlowFeedbackPrompt {

    private static let lastShownKey = "feedback_prompt_last_shown"
    /// KALICI DEĞER. Haftalık sınıra DÖNÜLMEYECEK (2026-08-26 kararı) — bu bir test ayarı değil.
    ///
    /// Haftalık sınır kâğıt üzerinde "kullanıcıyı yormayan ürün" gibi görünür, pratikte tersini
    /// yapar: 2026-08-24'te bir kullanıcı 60 saniye arayla İKİ FARKLI sebeple (anti-spoof, sonra
    /// çip imzası) düştü ve sınır ikinci raporu yuttu — tam da öğrenmemiz gereken vakayı.
    /// Her ayrı hata AYRI bir arıza yüzeyidir ve sorabildiğimiz tek an, hatanın hemen ardındaki
    /// andır. Sınırın işi AYNI olaydan doğan ikinci tetiği yutmaktır, farklı bir olayı susturmak
    /// değil — 60 saniye tam olarak bunu yapar.
    private static let interval: TimeInterval = 60

    /// Kayıt akışının hangi adımında takılındı — konu satırını ön-doldurmak için.
    enum FlowStep: String, CaseIterable {
        case mrz, nfc, liveness, submit

        var labelKey: String { "feedback_step_\(rawValue)" }

        /// Akıştaki sıra — "en ileri ulaşılan adım" karşılaştırması için.
        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    static func shouldOffer(now: Date = Date()) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastShownKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Kutu GÖSTERİLDİĞİNDE çağrılır (kullanıcı "hayır" dese de sayaç işler — asıl amaç sıklığı
    /// sınırlamak, cevabı kaydetmek değil).
    static func markShown(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastShownKey)
    }

    /// "Kart ekleme sorunu: Çip okuma" gibi hazır bir konu satırı.
    static func subject(for step: FlowStep) -> String {
        L.t("feedback_subject_card_add", L.t(step.labelKey))
    }
}
