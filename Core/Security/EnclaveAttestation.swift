import Foundation
import SwiftCBOR

/// Enclave (AWS Nitro) attestation belgesinden PCR0 çıkarımı — sunucu `PcrSignatureResolver.ExtractPcr0`
/// CBOR ayrıştırmasının iOS karşılığı. Güvenlik ekranı (Sistem Güvenliği) "Enclave Parmak İzi" gösterimi.
///
/// AWS Nitro attestation = COSE_Sign1 (4 elemanlı CBOR dizisi). 3. eleman (payload) bir CBOR map'tir;
/// anahtar 4 (veya "pcrs") = PCR map; PCR 0 = byte string. Lokal/mock belgeler düz map döner → PCR0 yok.
/// Tüm ayrıştırma best-effort: başarısızsa `nil` (ekran "N/A" gösterir, çökme yok).
enum EnclaveAttestation {

    static func extractPcr0(fromBase64 attestationDoc: String?) -> String? {
        guard let doc = attestationDoc, !doc.isEmpty,
              let data = Data(base64Encoded: doc),
              let top = try? CBOR.decode([UInt8](data)) else { return nil }

        // COSE_Sign1: [protected, unprotected, payload(byteString), signature]
        guard case let .array(arr) = top, arr.count == 4,
              case let .byteString(payloadBytes) = arr[2],
              let payload = try? CBOR.decode(payloadBytes),
              case let .map(payloadMap) = payload else { return nil }

        // pcrs: integer anahtar 4 (tercih) veya "pcrs"
        let pcrsValue = payloadMap[.unsignedInt(4)] ?? payloadMap[.utf8String("pcrs")]
        guard case let .map(pcrs)? = pcrsValue else { return nil }

        // PCR index 0 → byte string → hex
        guard case let .byteString(pcr0Bytes)? = pcrs[.unsignedInt(0)] else { return nil }
        return pcr0Bytes.map { String(format: "%02x", $0) }.joined()
    }
}
