import Foundation

/// Android `VerifyBlind_Prefs` + `user_prefs` (SharedPreferences) iOS UserDefaults portu.
///
/// `ticket` zaten hibrit-şifreli (HybridContent JSON) saklandığı için UserDefaults uygundur
/// (Android da SharedPreferences kullanır). Hassas ham tanımlayıcılar `SecureStore`'da (Keychain).
enum AppPrefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let ticket = "ticket"
        static let userPubKey = "userPubKey"
        static let expiryDate = "expiry_date"
        static let kvkkConsent = "kvkk_consent_accepted"
        static let biometricEnabled = "biometric_enabled"
        // Attestation teşhis bayrakları (Android last_* paritesi)
        static let lastPcr0 = "last_pcr0"
        static let lastHardwareVerified = "last_hardware_verified"
        static let lastIsMock = "last_is_mock"
        static let lastAttestationTime = "last_attestation_time"
    }

    /// Hibrit-şifreli ticket zarfı (HybridContent JSON string).
    static var ticket: String? {
        get { d.string(forKey: Key.ticket) }
        set { d.set(newValue, forKey: Key.ticket) }
    }

    static var userPubKey: String? {
        get { d.string(forKey: Key.userPubKey) }
        set { d.set(newValue, forKey: Key.userPubKey) }
    }

    static var expiryDate: String? {
        get { d.string(forKey: Key.expiryDate) }
        set { d.set(newValue, forKey: Key.expiryDate) }
    }

    static var kvkkConsentAccepted: Bool {
        get { d.bool(forKey: Key.kvkkConsent) }
        set { d.set(newValue, forKey: Key.kvkkConsent) }
    }

    static var biometricEnabled: Bool {
        get { d.bool(forKey: Key.biometricEnabled) }
        set { d.set(newValue, forKey: Key.biometricEnabled) }
    }

    static var lastPcr0: String? {
        get { d.string(forKey: Key.lastPcr0) }
        set { d.set(newValue, forKey: Key.lastPcr0) }
    }
    static var lastHardwareVerified: Bool {
        get { d.bool(forKey: Key.lastHardwareVerified) }
        set { d.set(newValue, forKey: Key.lastHardwareVerified) }
    }
    static var lastIsMock: Bool {
        get { d.bool(forKey: Key.lastIsMock) }
        set { d.set(newValue, forKey: Key.lastIsMock) }
    }
    static var lastAttestationTime: Int64 {
        get { Int64(d.integer(forKey: Key.lastAttestationTime)) }
        set { d.set(Int(newValue), forKey: Key.lastAttestationTime) }
    }

    /// Android `clearTicket()` — kart kaldırıldığında ticket+pubkey+expiry temizlenir.
    static func clearTicket() {
        d.removeObject(forKey: Key.ticket)
        d.removeObject(forKey: Key.userPubKey)
        d.removeObject(forKey: Key.expiryDate)
    }
}
