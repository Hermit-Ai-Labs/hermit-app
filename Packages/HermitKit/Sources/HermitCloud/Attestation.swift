import Foundation
import CryptoKit
import Security
import HermitCore

/// One NEAR-operated attestation report (the gateway's, or one model candidate), read from
/// `GET /v1/attestation/report`. Field meanings: docs.near.ai/cloud/verification/cloud-api/model-attestations.
public struct NearReport: Sendable {
    public struct Event: Sendable { let imr: Int; let eventType: UInt32; let event: String; let payload: String; let digest: String }

    public let modelName: String?
    public let signingAddress: String
    public let signingAlgo: String
    public let requestNonce: String?
    public let reportDataHex: String?
    public let tlsFingerprint: String?
    public let intelQuote: Data
    public let events: [Event]
    /// The raw `info.tcb_info.app_compose` string, never re-serialised.
    public let appCompose: String?
    public let appName: String?
    public let composeHash: String?
    public let osImageHash: String?
    public let instanceID: String?
    /// `nvidia_payload` as sent (a JSON string), for NVIDIA NRAS.
    public let nvidiaPayload: String?
    public let gpuNonce: String?
    public let gpuCount: Int
    public let gpuArch: String?

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        public var description: String { switch self { case .missing(let f): "The report has no \(f)" } }
    }

    init(_ j: [String: Any]) throws {
        func str(_ k: String) -> String? { j[k] as? String }
        func json(_ v: Any?) -> Any? {
            if let s = v as? String, let d = s.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: d) }
            return v
        }
        guard let addr = str("signing_address") else { throw Failure.missing("signing_address") }
        guard let algo = str("signing_algo") else { throw Failure.missing("signing_algo") }
        guard let q = str("intel_quote").flatMap(Data.init(hexString:)) else { throw Failure.missing("intel_quote") }
        modelName = str("model_name"); signingAddress = addr; signingAlgo = algo
        requestNonce = str("request_nonce"); reportDataHex = str("report_data"); tlsFingerprint = str("tls_cert_fingerprint")
        intelQuote = q
        events = ((json(j["event_log"]) as? [[String: Any]]) ?? []).map {
            Event(imr: ($0["imr"] as? NSNumber)?.intValue ?? -1, eventType: ($0["event_type"] as? NSNumber)?.uint32Value ?? 0,
                  event: $0["event"] as? String ?? "", payload: $0["event_payload"] as? String ?? "", digest: $0["digest"] as? String ?? "")
        }
        let info = j["info"] as? [String: Any]
        let tcb = json(info?["tcb_info"]) as? [String: Any]
        appCompose = tcb?["app_compose"] as? String
        appName = info?["app_name"] as? String
        composeHash = (info?["compose_hash"] ?? tcb?["compose_hash"]) as? String
        osImageHash = (info?["os_image_hash"] ?? tcb?["os_image_hash"]) as? String
        instanceID = info?["instance_id"] as? String
        nvidiaPayload = str("nvidia_payload")
        let gpu = json(j["nvidia_payload"]) as? [String: Any]
        gpuNonce = gpu?["nonce"] as? String
        gpuCount = (gpu?["evidence_list"] as? [Any])?.count ?? 0
        gpuArch = gpu?["arch"] as? String
    }

    /// RTMR3 from the event log: each IMR-3 event's digest is SHA-384(type LE32 || ":" || event || ":" || payload),
    /// extended from 48 zero bytes. Returns nil if an event's stated digest disagrees with its contents.
    func replayRTMR3() -> Data? {
        var rtmr = Data(count: 48)
        for e in events where e.imr == 3 {
            var t = e.eventType.littleEndian
            var m = Data(bytes: &t, count: 4)
            m += Data(":".utf8) + Data(e.event.utf8) + Data(":".utf8) + (Data(hexString: e.payload) ?? Data())
            let digest = Data(SHA384.hash(data: m))
            if !e.digest.isEmpty, Data(hexString: e.digest) != digest { return nil }
            rtmr = Data(SHA384.hash(data: rtmr + digest))
        }
        return rtmr
    }
}

/// A whole `/v1/attestation/report` response.
public struct AttestationBundle: Sendable {
    public let gateway: NearReport
    public let models: [NearReport]
    public let byteCount: Int

    public init(json data: Data) throws {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let g = j["gateway_attestation"] as? [String: Any] else { throw NearReport.Failure.missing("gateway_attestation") }
        gateway = try NearReport(g)
        models = try ((j["model_attestations"] as? [[String: Any]]) ?? []).map(NearReport.init)
        byteCount = data.count
    }
}

/// The checks in docs.near.ai/cloud/verification, done on this phone where that is possible.
public enum AttestationVerifier {
    /// Every check for one report. `group` is "Gateway enclave" or "Model enclave".
    public static func checks(_ r: NearReport, nonce: String, group: String, at date: Date = Date()) -> [CloudProof.Check] {
        let key = group == CloudProof.gatewayGroup ? "gw" : "model"
        func c(_ id: String, _ title: String, _ ok: Bool, _ detail: String = "") -> CloudProof.Check {
            CloudProof.Check(id: "\(key).\(id)", group: group, title: title, detail: detail, status: ok ? .pass : .fail)
        }
        var out: [CloudProof.Check] = []
        guard let q = try? TDXQuote(r.intelQuote) else {
            return [c("quote", "Intel TDX quote readable", false, "The quote could not be parsed")]
        }
        out.append(c("tdx", "Intel TDX quote, version 4", q.isTDXv4, "TEE type 0x\(String(q.teeType, radix: 16))"))

        let chain = q.verifyChain(at: date)
        out.append(c("qsig", "Quote signed by its attestation key", chain.quoteSigned, "ECDSA P-256 over the TD report"))
        out.append(c("qe", "Attestation key certified by Intel's Quoting Enclave", chain.keyBoundToQE && chain.qeSignedByPCK,
                     chain.qeSignedByPCK ? "QE report signed by the \(chain.pckName.isEmpty ? "PCK" : chain.pckName) key" : (chain.error ?? "QE report signature invalid")))
        out.append(c("root", "Certificate chain ends at Intel SGX Root CA", chain.chainToIntelRoot && chain.certificatesInDate,
                     chain.chainToIntelRoot ? (chain.certificatesInDate ? "Root byte-identical to Intel's, all in date" : "A certificate is out of date")
                                            : (chain.error ?? "Chain does not reach Intel's root")))
        out.append(c("debug", "Debug mode off", !q.debug, "TD_ATTRIBUTES \(q.tdAttributes.hex)"))

        // Freshness and identity: report data = signer (zero-padded to 32, or SHA-256(signer || TLS SPKI hash)) || nonce.
        let ours = Data(hexString: nonce) ?? Data()
        out.append(c("echo", "Nonce echoed back", r.requestNonce?.lowercased() == nonce.lowercased()))
        out.append(c("nonce", "Quote contains \(CloudDevice.here)'s nonce", ours.count == 32 && q.reportData.suffix(32) == ours, "Proves the quote was made for this request"))
        let ident = Data(hexString: r.signingAddress) ?? Data()
        let identOK = (r.signingAlgo == "ecdsa" && ident.count == 20) || (r.signingAlgo == "ed25519" && ident.count == 32)
        let bound: Data
        if let fp = r.tlsFingerprint.flatMap(Data.init(hexString:)) { bound = Data(SHA256.hash(data: ident + fp)) }
        else { bound = ident + Data(count: max(0, 32 - ident.count)) }
        out.append(c("signer", "Quote binds the signing key", identOK && q.reportData.prefix(32) == bound, short(r.signingAddress)))
        if let rd = r.reportDataHex {
            out.append(c("rdata", "Reported data matches the quote", Data(hexString: rd) == q.reportData))
        }

        // Measured configuration and runtime log.
        if let compose = r.appCompose {
            let h = Data(SHA256.hash(data: Data(compose.utf8)))
            out.append(c("config", "Configuration hash matches MRCONFIGID", q.mrConfigID == Data([1]) + h + Data(count: 15),
                         "app_compose sha256 \(h.hex.prefix(16))"))
        } else {
            out.append(c("config", "Configuration hash matches MRCONFIGID", false, "No app_compose in the report"))
        }
        let replay = r.replayRTMR3()
        out.append(c("rtmr3", "Event log replays to RTMR3", replay == q.rtmr[3], replay == nil ? "An event's digest is wrong" : "\(r.events.filter { $0.imr == 3 }.count) runtime events"))

        // Which guest OS booted. Known measurements pass. Unknown ones are listed as not checked, never as a failure,
        // so a new NEAR image doesn't lock anyone out before this list learns it.
        if let os = knownOSImage(q) {
            out.append(c("os", "Guest OS is one NEAR publishes", true, "\(os): firmware, kernel and root filesystem match its measurements"))
        } else {
            out.append(CloudProof.Check(id: "\(key).os", group: group, title: "Guest OS is one NEAR publishes",
                                        detail: "These measurements aren't in this build's list. near/verify-attestation.py checks them against NEAR's downloads",
                                        status: .skipped, source: .none))
        }

        if r.nvidiaPayload != nil {
            out.append(c("gpunonce", "GPU evidence carries \(CloudDevice.here)'s nonce", r.gpuNonce?.lowercased() == nonce.lowercased(),
                         "\(r.gpuCount) \(r.gpuArch.map { $0.capitalized } ?? "NVIDIA") GPUs"))
        }
        return out
    }

    /// The guest OS images NEAR publishes in github.com/nearai/dstack-images, by what a TDX machine measures when it
    /// boots them: MRTD is the firmware (QEMU 8 and QEMU 9+ add its pages in a different order, hence two values),
    /// RTMR1 the kernel, RTMR2 the kernel command line (which pins the root filesystem) and the initramfs.
    /// `near/verify-attestation.py` recomputes all of them from NEAR's downloads and carries the same table
    /// (KNOWN_OS_IMAGES, recomputed 2026-11-12). RTMR0, the virtual hardware tables, is not compared.
    static let knownMRTD: Set<String> = [
        "7fe60787222bd394cb516abca2435f22f035ab2cc9c0a4b4b3b148e46297f3d931a237b72f359052c6e657d8c1409173",
        "df4d77c857de652bd0fafa343a2026b51071ee03773d076d283abf1a7d36ff91ffa279ee4a617ac664f7e2a2c8d5891b",
    ]
    static let knownRTMR1 = "4ae609807c765916a31d724786ed74bcb97e168a9d937b04936aeef2015c907eba5ac352c6bcd749c246fd62ffb659ec"
    /// RTMR2 to image name.
    static let knownOSImages: [String: String] = [
        "764489f277a8540189761e72b4238ba36d4d647e11bd958d8ab5522af2a4867b0ff63e06b0c4967f1857236244040a5d": "dstack-0.5.12",
        "bd67ab7554dc27ab03a077bc1447a1a67d0624ff547c4c809a8626f12d6a89712f8ec60e781e99b98208574065d21a71": "dstack-nvidia-0.5.12",
    ]

    /// The published image these measurements belong to, or nil when this build doesn't know them.
    static func knownOSImage(_ q: TDXQuote) -> String? {
        guard knownMRTD.contains(q.mrTD.hex), q.rtmr[1].hex == knownRTMR1 else { return nil }
        return knownOSImages[q.rtmr[2].hex]
    }

    /// The measurements to show, read from the quote (not from the HTTP fields).
    public static func measurements(_ r: NearReport) -> [[String]] {
        guard let q = try? TDXQuote(r.intelQuote) else { return [] }
        var rows = [["MRTD", q.mrTD.hex]] + q.rtmr.enumerated().map { ["RTMR\($0.offset)", $0.element.hex] }
        rows.append(["MRCONFIGID", q.mrConfigID.hex])
        if let h = r.composeHash { rows.append(["Compose hash", h]) }
        if let o = r.osImageHash { rows.append(["OS image", o]) }
        if let a = r.appName { rows.append(["App", a]) }
        return rows
    }

    public static func teeName(_ models: [NearReport]) -> String {
        guard let m = models.first else { return "Intel TDX" }
        if m.gpuCount > 0 { return "Intel TDX + \(m.gpuCount) \(m.gpuArch.map { $0.capitalized } ?? "NVIDIA") GPUs in confidential mode" }
        return "Intel TDX"
    }

    static func short(_ a: String) -> String { a.count > 14 ? "\(a.prefix(8))…\(a.suffix(6))" : a }

    /// 32 fresh random bytes from the system CSPRNG, hex.
    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(ok == errSecSuccess, "No system randomness")
        return Data(bytes).hex
    }
}
