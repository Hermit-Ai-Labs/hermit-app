import Foundation

/// What Hermit checked about one Private Cloud reply (NEAR AI Cloud, inside a TEE), shown in the Verified sheet.
/// Every check says who did it: this phone, a named remote verifier, or nobody. Nothing here is ever assumed.
public struct CloudProof: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable { case pass, fail, skipped }
    /// Who did the check. `remote` names the verifier in `detail` (for example NVIDIA NRAS).
    public enum Source: String, Equatable, Sendable, Codable { case device, remote, none }

    public struct Check: Equatable, Sendable, Codable, Identifiable {
        public var id: String
        /// "Model enclave", "Gateway enclave", "This reply".
        public var group: String
        public var title: String
        public var detail: String
        public var status: Status
        public var source: Source
        public init(id: String, group: String, title: String, detail: String = "", status: Status, source: Source = .device) {
            self.id = id; self.group = group; self.title = title; self.detail = detail; self.status = status; self.source = source
        }
    }

    /// Canonical model ID, as sent with x-no-aliasing.
    public var model: String
    /// "Intel TDX + NVIDIA H200 (confidential computing)" from the evidence, or what was found.
    public var tee: String
    /// The 32 random bytes (hex) this phone generated for the attestation request.
    public var nonce: String
    public var fetchedAt: Date
    public var repliedAt: Date?
    /// "provider_tee" (signed by the model enclave) or "gateway" (signed by the gateway enclave).
    public var signatureKind: String?
    public var modelSigner: String?
    public var gatewaySigner: String?
    /// Measurements as read from the quote: MRTD, RTMR0-3, compose hash.
    public var measurements: [[String]]
    public var checks: [Check]
    /// Completions in this reply (a reply with tool calls takes several); how many had a verified signature.
    public var completions: Int
    public var signedCompletions: Int

    public init(model: String, tee: String, nonce: String, fetchedAt: Date, repliedAt: Date? = nil, signatureKind: String? = nil,
                modelSigner: String? = nil, gatewaySigner: String? = nil, measurements: [[String]] = [], checks: [Check] = [],
                completions: Int = 0, signedCompletions: Int = 0) {
        self.model = model; self.tee = tee; self.nonce = nonce; self.fetchedAt = fetchedAt; self.repliedAt = repliedAt
        self.signatureKind = signatureKind; self.modelSigner = modelSigner; self.gatewaySigner = gatewaySigner
        self.measurements = measurements; self.checks = checks; self.completions = completions; self.signedCompletions = signedCompletions
    }

    public var failed: [Check] { checks.filter { $0.status == .fail } }
    /// The enclave evidence passed every check that ran.
    public var enclaveVerified: Bool { failed.isEmpty && checks.contains { $0.group != Self.replyGroup && $0.status == .pass } }
    /// Evidence passed and every completion in the reply carried a signature from the attested model enclave.
    public var fullyVerified: Bool { enclaveVerified && completions > 0 && signedCompletions == completions && signatureKind == "provider_tee" }

    /// One line for the chip under a reply.
    public var headline: String {
        if !failed.isEmpty { return "Not verified" }
        if fullyVerified { return "Verified in a TEE" }
        if enclaveVerified { return completions == 0 ? "Enclave verified" : "Enclave verified, reply signature missing" }
        return "Not verified"
    }

    public static let modelGroup = "Model enclave"
    public static let gatewayGroup = "Gateway enclave"
    public static let replyGroup = "This reply"
}
