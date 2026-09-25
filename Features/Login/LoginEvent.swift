import CryptoKit
import Foundation

/// Doğrulamanın TEK hareketi — QR isteğinin nonce'undan türetilir (2026-09-26).
///
/// Enclave `ChoreographyGenerator.ForLogin` kuralının BİREBİR kopyası (Android `LoginEvent` de).
/// Neden istemcide de var: login-handshake QR okunmadan, nonce bilinmeden hazırlanıyor; sunucunun
/// hareketi söyleyeceği bir tur yok. Karar yine enclave'de — burada yanlış türetilirse kanıt
/// istenen hareketle uyuşmaz ve doğrulama reddedilir. Türetme değişirse üç yer birlikte değişir;
/// test vektörleri üçünde de aynı (`LoginEventTests`).
///
/// Düz kırpma listede YOK: her videoda kendiliğinden var, tek hareketlik dizide videoyu zorlamaz.
enum LoginEvent {

    private static let domain = "vb-choreo-login-v2|"

    /// Sıra türetmenin parçası — enclave'deki `LoginEvents` ile aynı, değiştirilmez.
    private static let events: [EventSequencer.Event] = [.smile, .mouthOpen, .doubleBlink]

    static func forNonce(_ nonce: String) -> EventSequencer.Event? {
        guard !nonce.isEmpty else { return nil }
        var draw = DeterministicDraw(seed: Data(SHA256.hash(data: Data((domain + nonce).utf8))))
        return events[draw.next(events.count)]
    }

    /// SHA-256 sayaç kipi, reddetme örneklemeli yansız çekiliş — enclave `DeterministicDraw`.
    /// Blok = SHA256(tohum ‖ sayaç, 4 bayt little-endian); değer = bloktan 4 bayt little-endian.
    private struct DeterministicDraw {
        let seed: Data
        private var block: [UInt8] = []
        private var offset = 0
        private var counter: UInt32 = 0

        init(seed: Data) { self.seed = seed }

        mutating func next(_ n: Int) -> Int {
            let limit = UInt32.max - (UInt32.max % UInt32(n))
            while true {
                let v = nextUInt()
                if v < limit { return Int(v % UInt32(n)) }
            }
        }

        private mutating func nextUInt() -> UInt32 {
            if offset + 4 > block.count {
                var input = seed
                withUnsafeBytes(of: counter.littleEndian) { input.append(contentsOf: $0) }
                counter &+= 1
                block = Array(SHA256.hash(data: input))
                offset = 0
            }
            let v = UInt32(block[offset])
                | UInt32(block[offset + 1]) << 8
                | UInt32(block[offset + 2]) << 16
                | UInt32(block[offset + 3]) << 24
            offset += 4
            return v
        }
    }
}
