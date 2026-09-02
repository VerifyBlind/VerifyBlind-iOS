import SwiftUI

/// Yardım ("Nasıl Çalışır") içeriği — Android `ui/HelpContent.kt` portu. Metinler ayrı `Help.strings`
/// tablosundan (`L.help`) gelir; bu model yalnız sıra/ikon/renk + anahtar eşlemesini tutar.

struct HelpGuide: Identifiable {
    let id = UUID()
    let titleKey: String
    let icon: String          // SF Symbol (Android drawable karşılığı)
    let tint: Color
    let purposeKey: String
    let stepsKey: String
    let troubleshootingKey: String
    let securityNoteKey: String
}

struct HelpFaqCategory: Identifiable {
    let id = UUID()
    let titleKey: String
    let color: Color
    let questionsBase: String  // ör. "faq_cat_security_questions"
    let answersBase: String
    let count: Int
}

enum HelpData {
    /// Android `HelpContent.getScreenGuides` 9 rehberi (ikon tint hex'leri Android'den birebir).
    static let guides: [HelpGuide] = [
        HelpGuide(titleKey: "guide_wallet_title", icon: "creditcard", tint: Color(hex: "#0060AA"),
                  purposeKey: "guide_wallet_purpose", stepsKey: "guide_wallet_steps",
                  troubleshootingKey: "guide_wallet_troubleshooting", securityNoteKey: "guide_wallet_security_note"),
        HelpGuide(titleKey: "guide_add_card_title", icon: "plus.rectangle.on.rectangle", tint: Color(hex: "#00897B"),
                  purposeKey: "guide_add_card_purpose", stepsKey: "guide_add_card_steps",
                  troubleshootingKey: "guide_add_card_troubleshooting", securityNoteKey: "guide_add_card_security_note"),
        HelpGuide(titleKey: "guide_nfc_title", icon: "wave.3.right", tint: Color(hex: "#00897B"),
                  purposeKey: "guide_nfc_purpose", stepsKey: "guide_nfc_steps",
                  troubleshootingKey: "guide_nfc_troubleshooting", securityNoteKey: "guide_nfc_security_note"),
        HelpGuide(titleKey: "guide_liveness_title", icon: "face.smiling", tint: Color(hex: "#2E7D32"),
                  purposeKey: "guide_liveness_purpose", stepsKey: "guide_liveness_steps",
                  troubleshootingKey: "guide_liveness_troubleshooting", securityNoteKey: "guide_liveness_security_note"),
        HelpGuide(titleKey: "guide_qr_login_title", icon: "qrcode.viewfinder", tint: Color(hex: "#6A1B9A"),
                  purposeKey: "guide_qr_login_purpose", stepsKey: "guide_qr_login_steps",
                  troubleshootingKey: "guide_qr_login_troubleshooting", securityNoteKey: "guide_qr_login_security_note"),
        HelpGuide(titleKey: "guide_history_title", icon: "clock.arrow.circlepath", tint: Color(hex: "#0060AA"),
                  purposeKey: "guide_history_purpose", stepsKey: "guide_history_steps",
                  troubleshootingKey: "guide_history_troubleshooting", securityNoteKey: "guide_history_security_note"),
        HelpGuide(titleKey: "guide_settings_title", icon: "gearshape", tint: Color(hex: "#00897B"),
                  purposeKey: "guide_settings_purpose", stepsKey: "guide_settings_steps",
                  troubleshootingKey: "guide_settings_troubleshooting", securityNoteKey: "guide_settings_security_note"),
        HelpGuide(titleKey: "guide_security_info_title", icon: "lock.shield", tint: Color(hex: "#2E7D32"),
                  purposeKey: "guide_security_info_purpose", stepsKey: "guide_security_info_steps",
                  troubleshootingKey: "guide_security_info_troubleshooting", securityNoteKey: "guide_security_info_security_note"),
        HelpGuide(titleKey: "guide_backup_title", icon: "lock.icloud", tint: Color(hex: "#00897B"),
                  purposeKey: "guide_backup_purpose", stepsKey: "guide_backup_steps",
                  troubleshootingKey: "guide_backup_troubleshooting", securityNoteKey: "guide_backup_security_note"),
    ]

    /// Android `getFaqCategories` 4 kategorisi (renk hex'leri + soru/cevap sayıları birebir).
    static let faqCategories: [HelpFaqCategory] = [
        HelpFaqCategory(titleKey: "faq_cat_security_title", color: Color(hex: "#0060AA"),
                        questionsBase: "faq_cat_security_questions", answersBase: "faq_cat_security_answers", count: 5),
        HelpFaqCategory(titleKey: "faq_cat_usage_title", color: Color(hex: "#2E7D32"),
                        questionsBase: "faq_cat_usage_questions", answersBase: "faq_cat_usage_answers", count: 6),
        HelpFaqCategory(titleKey: "faq_cat_troubleshooting_title", color: Color(hex: "#D67400"),
                        questionsBase: "faq_cat_troubleshooting_questions", answersBase: "faq_cat_troubleshooting_answers", count: 4),
        HelpFaqCategory(titleKey: "faq_cat_support_title", color: Color(hex: "#6A1B9A"),
                        questionsBase: "faq_cat_support_questions", answersBase: "faq_cat_support_answers", count: 3),
    ]
}
