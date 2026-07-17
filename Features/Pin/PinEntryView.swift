import SwiftUI

/// TCKN'siz kimliklerin bulut yedek PIN'ini toplayan yeniden kullanılabilir SwiftUI ekranı —
/// Android `ui/pin/PinDialog.kt` paritesi.
///
/// KAPSAM NOTU: PIN akışı bugün uçtan uca ÇALIŞMAZ — TCKN'siz belgeler `DocumentSupport` tarafından
/// reddediliyor (yabancı belge desteği B-4'te gelecek). Bu, B-4'ün bağlayacağı temiz dikiştir.
///
/// Güvenlik kararları:
///  - Numeric klavye, `PinValidator.isValid` = en az 6 hane (yaygın-PIN blocklist YOK — kullanıcı kararı).
///  - Kurulum ekranında kurtarma uyarısı: PIN unutulursa geçmiş kalıcı gider.
///  - PIN doğruluğu SUNUCUDA/wrap açılışında anlaşılır; bu ekran yalnız biçimsel geçerliliği denetler.
struct PinEntryView: View {

    enum Mode {
        case setup           // kurulum: gir + doğrula
        case entry           // giriş (restore / 2. cihaz)
        case entryChanged    // 2. cihazda "PIN değişmiş"

        var titleKey: String {
            switch self {
            case .setup: return "pin_setup_title"
            case .entry: return "pin_enter_title"
            case .entryChanged: return "pin_changed_reenter"
            }
        }
        var showsWarning: Bool { self == .setup }
        var descriptionKey: String? { self == .setup ? "pin_setup_desc" : nil }
    }

    let mode: Mode
    /// Geçerli ve (setup'ta) doğrulanmış PIN. Çağıran taraf bununla derive/DEK-wrap işini yapar.
    let onSubmit: (String) -> Void
    var onCancel: (() -> Void)?

    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                if let d = mode.descriptionKey {
                    Section { Text(L.t(d)).font(.footnote).foregroundColor(.secondary) }
                }

                Section {
                    SecureField(L.t("pin_enter_title"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if mode == .setup {
                        SecureField(L.t("pin_confirm_title"), text: $confirm)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }

                if let error {
                    Section { Text(error).foregroundColor(.red).font(.footnote) }
                }

                if mode.showsWarning {
                    Section {
                        Text(L.t("pin_warning_forgot"))
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(L.t(mode.titleKey))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common_ok")) { submit() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("btn_cancel")) { onCancel?() }
                }
            }
        }
    }

    private func submit() {
        guard PinValidator.isValid(pin) else {
            error = L.t("pin_min_length")
            return
        }
        if mode == .setup && pin != confirm {
            error = L.t("pin_mismatch")
            return
        }
        error = nil
        onSubmit(pin)
    }
}
