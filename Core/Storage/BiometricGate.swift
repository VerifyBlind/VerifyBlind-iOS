import Foundation
import LocalAuthentication

/// Basit biyometrik kapı (kripto işlemi olmadan) — Android `BiometricHelper.authenticate` eşdeğeri.
/// Kart silme gibi onay-gerektiren ama anahtar kullanmayan işlemler için. Ticket decrypt'i
/// `KeychainKeyStore.decryptWithUserKey` kendi promptunu yönetir.
enum BiometricGate {
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
