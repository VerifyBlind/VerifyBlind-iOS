import Foundation
import LocalAuthentication

/// Basit biyometrik kapı (kripto işlemi olmadan) — Android `BiometricHelper.authenticate` eşdeğeri.
/// Kart silme gibi onay-gerektiren ama anahtar kullanmayan işlemler için. Ticket decrypt'i
/// `KeychainKeyStore.decryptWithUserKey` kendi promptunu yönetir.
enum BiometricGate {

    /// Cihaz kilidi (biyometri VEYA passcode) kullanılabilir mi — anahtar ÜRETMEDEN ÖNCE kontrol.
    ///
    /// `KeychainKeyStore.ensureUserKey` anahtarı `.userPresence` erişim kontrolüyle üretir; bu
    /// "biyometri VEYA passcode" demektir. Cihazda hiç kilit yoksa `SecKeyCreateRandomKey`
    /// `errSecAuthFailed` (-25293) ile düşer ve kullanıcı sebebini anlamaz. `.deviceOwnerAuthentication`
    /// politikası `.userPresence` ile aynı kapsamı ölçer → doğru ön kontrol budur.
    ///
    /// NOT: Android'de kapsam DAHA DARDIR (`setUserAuthenticationRequired(true)` + BIOMETRIC_STRONG),
    /// orada passcode yetmez ve kayıtlı biyometri şarttır — bu yüzden Android'de hata çok daha sık.
    static func isDeviceLockAvailable() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if !ok {
            Log.warning("Cihaz kilidi kullanılamıyor: \(error?.localizedDescription ?? "bilinmiyor")", category: .flow)
        }
        return ok
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: BiometricGateError.failed(error?.localizedDescription ?? "iptal"))
                }
            }
        }
    }
}

enum BiometricGateError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m }
    }
}
