import Foundation

/// İmzalı ticket'in yerel hibrit-şifreli saklanması/çözülmesi — Android `MainViewModel.saveTicket` /
/// `clearTicket` + biyometrik decrypt (`getCipherForDecrypt`) paritesi.
///
/// Saklama: AES-256-GCM (rastgele key) + AES anahtarı user public key ile RSA-OAEP-SHA1 sarılır
/// (`rsaEncryptForKeystore`). Çözme: biyometrik → `KeychainKeyStore.decryptWithUserKey`.
enum TicketStore {

    static var hasTicket: Bool { AppPrefs.ticket != nil }

    /// Android `saveTicket(ticket, pubKey)`. `signedTicketJson` RAW ticket JSON (alan kaybı yok).
    static func save(signedTicketJson: String, pubKey: String) throws {
        let (blob, aesKey) = try CryptoUtils.aesEncrypt(signedTicketJson)
        let encKey = try CryptoUtils.rsaEncryptForKeystore(aesKey, publicKeyBase64: pubKey)
        let hybrid = HybridContent(encKey: encKey, blob: blob)
        let data = try JSONEncoder().encode(hybrid)
        AppPrefs.ticket = String(decoding: data, as: UTF8.self)
        AppPrefs.userPubKey = pubKey
    }

    static func loadEncrypted() -> HybridContent? {
        guard let json = AppPrefs.ticket, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HybridContent.self, from: data)
    }

    /// Biyometrik decrypt → saklı SignedTicket'in RAW JSON'ı (login sarmalına aynen gömülür).
    static func decryptSignedTicket(reason: String) async throws -> String {
        guard let hybrid = loadEncrypted() else { throw TicketStoreError.noTicket }
        let aesKey = try await KeychainKeyStore.decryptWithUserKey(hybrid.encKey, reason: reason)
        return try CryptoUtils.aesDecrypt(blobBase64: hybrid.blob, keyBase64: aesKey)
    }

    /// Android `clearTicket()` — prefs ticket/pubkey/expiry temizler (key silme + SecureStore wallet akışında).
    static func clear() {
        AppPrefs.clearTicket()
    }
}

enum TicketStoreError: Error, CustomStringConvertible {
    case noTicket
    var description: String { "noTicket" }
    var localizedDescription: String { description }
}
