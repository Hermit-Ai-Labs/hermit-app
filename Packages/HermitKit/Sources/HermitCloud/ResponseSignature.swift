import Foundation
import CryptoKit
import CryptoSwift
import libsecp256k1

/// `GET /v1/signature/{id}`: the enclave's signature over a completion's exact request and response bytes.
public struct ResponseSignature: Sendable, Equatable {
    public let text: String
    public let signature: String
    public let signingAddress: String
    public let signingAlgo: String
    /// "provider_tee" (model enclave) or "gateway". nil when the server didn't say.
    public let kind: String?

    public init(text: String, signature: String, signingAddress: String, signingAlgo: String, kind: String?) {
        self.text = text; self.signature = signature; self.signingAddress = signingAddress; self.signingAlgo = signingAlgo; self.kind = kind
    }

    init?(json: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: json) as? [String: Any], j["error_code"] == nil,
              let t = j["text"] as? String, let s = j["signature"] as? String,
              let a = j["signing_address"] as? String, let al = j["signing_algo"] as? String else { return nil }
        self.init(text: t, signature: s, signingAddress: a, signingAlgo: al, kind: j["signature_kind"] as? String)
    }

    /// What the signed text must be for these exact bytes (docs.near.ai/cloud/verification/cloud-api/response-signatures).
    public static func expectedText(request: Data, response: Data, model: String?) -> String {
        let h = "\(Data(CryptoKit.SHA256.hash(data: request)).hex):\(Data(CryptoKit.SHA256.hash(data: response)).hex)"
        return model.map { "\($0):\(h)" } ?? h
    }

    public enum Outcome: Equatable, Sendable {
        case verified
        case textMismatch
        case badSignature
        case signerMismatch(recovered: String)
        case unsupported(String)
    }

    /// Checks the signature over `text`, then that the signer is `expectedSigner` (from verified preflight evidence).
    public func verify(expectedText: String, expectedSigner: String, expectedAlgo: String) -> Outcome {
        guard text == expectedText else { return .textMismatch }
        guard signingAlgo == expectedAlgo else { return .unsupported("algorithm \(signingAlgo), expected \(expectedAlgo)") }
        switch signingAlgo {
        case "ecdsa":
            guard let recovered = Self.recoverEIP191(message: Data(text.utf8), signature: signature) else { return .badSignature }
            guard recovered.lowercased() == expectedSigner.lowercased(), signingAddress.lowercased() == expectedSigner.lowercased() else {
                return .signerMismatch(recovered: recovered)
            }
            return .verified
        case "ed25519":
            guard let key = Data(hexString: expectedSigner), let sig = Data(hexString: signature),
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return .badSignature }
            guard signingAddress.lowercased() == expectedSigner.lowercased() else { return .signerMismatch(recovered: signingAddress) }
            return pub.isValidSignature(sig, for: Data(text.utf8)) ? .verified : .badSignature
        default:
            return .unsupported(signingAlgo)
        }
    }

    /// Ethereum personal_sign recovery: keccak256("\u{19}Ethereum Signed Message:\n" + len + message), then the
    /// address is the last 20 bytes of keccak256 of the recovered public key.
    public static func recoverEIP191(message: Data, signature hex: String) -> String? {
        guard let sig = Data(hexString: hex), sig.count == 65 else { return nil }
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8)
        let digest = SHA3(variant: .keccak256).calculate(for: [UInt8](prefix + message))
        var v = Int32(sig[64])
        if v >= 27 { v -= 27 }
        guard v == 0 || v == 1 else { return nil }
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else { return nil }
        defer { secp256k1_context_destroy(ctx) }
        var rsig = secp256k1_ecdsa_recoverable_signature()
        let rs = [UInt8](sig.prefix(64))
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &rsig, rs, v) == 1 else { return nil }
        var pub = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(ctx, &pub, &rsig, digest) == 1 else { return nil }
        var out = [UInt8](repeating: 0, count: 65), len = 65
        guard secp256k1_ec_pubkey_serialize(ctx, &out, &len, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1 else { return nil }
        let hash = SHA3(variant: .keccak256).calculate(for: Array(out.dropFirst()))
        return "0x" + Data(hash.suffix(20)).hex
    }
}
