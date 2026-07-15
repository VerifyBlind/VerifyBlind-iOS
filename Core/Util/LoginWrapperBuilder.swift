import Foundation

/// Login sarmalı kurucu — Android `MainViewModel.completeLogin` wrapper'ı:
/// `{"signed_ticket": <ticket obj>, "nonce": "...", "pk_hash"?: "..."}`.
/// Ticket RAW JSON olarak gömülür (typed round-trip yapılmaz → imza alanları korunur).
enum LoginWrapperBuilder {
    static func build(signedTicketJson: String, nonce: String, pkHash: String?) throws -> String {
        let ticketObj = try JSONSerialization.jsonObject(with: Data(signedTicketJson.utf8))
        var wrapper: [String: Any] = ["signed_ticket": ticketObj, "nonce": nonce]
        if let pkHash, !pkHash.isEmpty { wrapper["pk_hash"] = pkHash }
        let data = try JSONSerialization.data(withJSONObject: wrapper, options: [])
        return String(decoding: data, as: UTF8.self)
    }
}
