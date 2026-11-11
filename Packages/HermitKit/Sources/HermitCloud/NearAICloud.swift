import Foundation
import CryptoKit
import HermitCore

/// NEAR AI Cloud's OpenAI-compatible gateway (cloud-api.near.ai). Attestation and the model list need no key;
/// completions and signatures need the user's key, which lives in the Keychain (`NearAICloud.apiKey`).
public struct NearAICloud: Sendable {
    public static let base = URL(string: "https://cloud-api.near.ai/v1")!
    public static let nras = URL(string: "https://nras.attestation.nvidia.com/v3/attest/gpu")!
    /// NVIDIA's keys for NRAS tokens, and the issuer the tokens must name.
    public static let nrasKeys = URL(string: "https://nras.attestation.nvidia.com/.well-known/jwks.json")!
    static let nrasIssuer = "https://nras.attestation.nvidia.com"
    public static let dashboard = URL(string: "https://cloud.near.ai")!
    public static let builders = URL(string: "https://nearbuilders.org/join")!
    public static let verificationCenter = URL(string: "https://cloud.near.ai/verify")!
    /// NEAR's Verification Center for one model.
    public static func verifyURL(model: String) -> URL {
        var c = URLComponents(url: verificationCenter, resolvingAgainstBaseURL: false)
        c?.queryItems = [.init(name: "model", value: model)]
        return c?.url ?? verificationCenter
    }
    /// Same family as Hermit 1.1 on the phone (Qwen3), 27B, run by NEAR inside Intel TDX + NVIDIA confidential GPUs.
    public static let defaultModel = "Qwen/Qwen3.8-27B"

    static let keyName = "near-ai-cloud.api-key"
    static let modelKey = "hermit.cloud.model"

    /// The user's own key from cloud.near.ai, in the Keychain on this device only.
    public static var ownKey: String? {
        get { Secrets.get(keyName).flatMap { $0.isEmpty ? nil : $0 } }
        set { saveOwnKey(newValue) }
    }

    /// Saves (nil or "" removes) the user's own key. False when the Keychain refused: the old key is still there.
    @discardableResult public static func saveOwnKey(_ key: String?) -> Bool {
        Secrets.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: keyName)
    }

    /// Hermit's shared key, so anyone can try Private Cloud without signing up. It is added to the app at build time
    /// (Resources/shared.bin, never in git), masked, and limited per device per day (`SharedQuota`).
    static let sharedKey: String? = {
        guard let url = Bundle.module.url(forResource: "shared", withExtension: "bin"),
              let d = try? Data(contentsOf: url), let b = Data(base64Encoded: d) else { return nil }
        let mask = Array("hermit-private-cloud".utf8)
        let key = String(decoding: b.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }, as: UTF8.self)
        return key.hasPrefix("sk-") ? key : nil
    }()

    /// The key a message goes out with: the user's own, else the shared one while today's free messages last.
    public static var apiKey: String? { ownKey ?? (SharedQuota.left > 0 ? sharedKey : nil) }
    /// True when there's no own key and the build carries the shared one.
    public static var usesSharedKey: Bool { ownKey == nil && sharedKey != nil }
    public static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case http(Int, String)
        case noKey
        case bad(String)
        public var description: String {
            switch self {
            case .http(401, _), .http(403, _): "NEAR AI Cloud didn't accept the API key. Check it in Settings, Private Cloud."
            case .http(402, _): "Your NEAR AI Cloud credits have run out. Add credits at cloud.near.ai."
            case .http(429, _): "NEAR AI Cloud is busy. Try again in a moment."
            case .http(let c, let m): "NEAR AI Cloud answered \(c)\(m.isEmpty ? "" : ": \(m.prefix(160))")"
            case .noKey: "Add your NEAR AI Cloud API key in Settings, Private Cloud."
            case .bad(let s): s
            }
        }
    }

    // MARK: Models

    public struct Model: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let contextLength: Int
        public let inputPrice: Double     // USD per million tokens
        public let outputPrice: Double
        public let tools: Bool
    }

    /// Open models NEAR runs itself in TEEs (owned_by "nearai") that can call tools, the default first.
    public func models() async throws -> [Model] {
        let data = try await get(Self.base.appending(path: "models"))
        return Self.teeModels(data)
    }

    static func teeModels(_ data: Data) -> [Model] {
        let list = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        let out: [Model] = list.compactMap { m in
            guard let id = m["id"] as? String, m["owned_by"] as? String == "nearai", m["is_ready"] as? Bool != false,
                  (m["supported_features"] as? [String])?.contains("tools") == true,
                  (m["output_modalities"] as? [String] ?? ["text"]).contains("text"),
                  !id.lowercased().contains("abliterated") else { return nil }
            let p = m["pricing"] as? [String: Any]
            return Model(id: id, name: m["name"] as? String ?? id, contextLength: m["context_length"] as? Int ?? 0,
                         inputPrice: (p?["input"] as? NSNumber)?.doubleValue ?? 0, outputPrice: (p?["output"] as? NSNumber)?.doubleValue ?? 0,
                         tools: true)
        }
        return out.sorted { ($0.id == defaultModel ? 0 : 1, $0.id) < ($1.id == defaultModel ? 0 : 1, $1.id) }
    }

    // MARK: Attestation

    /// Gateway and NEAR model evidence for `model`, made for `nonce`. No key is sent, so nothing identifying leaves
    /// the phone before the enclave is checked.
    /// With `tls`, the report is read on that watched connection and binds its TLS key (include_tls_fingerprint=true).
    public func attestation(model: String, nonce: String, tls: GatewayConnection? = nil) async throws
        -> (raw: Data, bundle: AttestationBundle, use: GatewayConnection.Use?) {
        var c = URLComponents(url: Self.base.appending(path: "attestation/report"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "model", value: model), .init(name: "provider", value: "near"),
                        .init(name: "signing_algo", value: "ecdsa"), .init(name: "nonce", value: nonce),
                        .init(name: "include_tls_fingerprint", value: tls == nil ? "false" : "true")]
        var req = URLRequest(url: c.url!, timeoutInterval: 60)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("true", forHTTPHeaderField: "x-no-aliasing")
        if let tls {
            let (data, resp, use) = try await tls.data(for: req)
            try Self.ok(resp, data)
            return (data, try AttestationBundle(json: data), use)
        }
        let (data, resp) = try await session.data(for: req)
        try Self.ok(resp, data)
        return (data, try AttestationBundle(json: data), nil)
    }

    /// NVIDIA's attestation service: sends only the GPU evidence (no prompt, no key) and reads the overall verdict
    /// from the returned token, after checking the token as NEAR's SDK does (`nrasVerdict`). nil: no verdict came back.
    public func nvidiaVerdict(_ payload: String, nonce: String) async -> (ok: Bool?, detail: String) {
        var req = URLRequest(url: Self.nras, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(payload.utf8)
        guard let result = try? await session.data(for: req) else { return (nil, "NVIDIA NRAS unreachable") }
        let (data, resp) = result
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = arr.first as? [Any],
              first.count == 2, let token = first[1] as? String else { return (false, "NVIDIA NRAS answered \(code)") }
        guard let keys = try? await get(Self.nrasKeys) else { return (nil, "NVIDIA's token keys unreachable") }
        let v = Self.nrasVerdict(token: token, keys: keys, nonce: nonce, at: Date())
        return (v.ok, v.detail)
    }

    /// Checks an NRAS token the way NEAR's SDK does: an ES384 signature by the NVIDIA key its header names (from
    /// NVIDIA's key set), NVIDIA as the issuer, inside its validity window, and `eat_nonce` equal to this request's
    /// nonce (so a token for other evidence can't be replayed). Only then is the overall verdict read.
    static func nrasVerdict(token: String, keys: Data, nonce: String, at date: Date) -> (ok: Bool, detail: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = base64URLDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = jwtClaims(token) else { return (false, "Unreadable NRAS token") }
        guard header["alg"] as? String == "ES384", let kid = header["kid"] as? String else { return (false, "NRAS token isn't signed with ES384") }
        let set = ((try? JSONSerialization.jsonObject(with: keys) as? [String: Any])?["keys"] as? [[String: Any]]) ?? []
        guard let jwk = set.first(where: { $0["kid"] as? String == kid }), jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-384",
              let x = (jwk["x"] as? String).flatMap({ base64URLDecode($0) }), let y = (jwk["y"] as? String).flatMap({ base64URLDecode($0) }),
              x.count == 48, y.count == 48, let key = try? P384.Signing.PublicKey(rawRepresentation: x + y) else {
            return (false, "NRAS token key isn't one of NVIDIA's")
        }
        guard let raw = base64URLDecode(parts[2]), raw.count == 96, let sig = try? P384.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8)) else {
            return (false, "NRAS token signature doesn't verify")
        }
        guard claims["iss"] as? String == nrasIssuer else { return (false, "NRAS token isn't from NVIDIA's issuer") }
        // A minute of clock skew either way.
        let now = date.timeIntervalSince1970
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue, let nbf = (claims["nbf"] as? NSNumber)?.doubleValue,
              nbf - 60 <= now, now < exp + 60 else { return (false, "NRAS token is out of date") }
        guard let eat = claims["eat_nonce"] as? String, eat.lowercased() == nonce.lowercased() else {
            return (false, "NRAS token is for another request's nonce")
        }
        let ok = claims["x-nvidia-overall-att-result"] as? Bool == true
        return (ok, ok ? "Verdict from NVIDIA NRAS: overall attestation true. Token signed by NVIDIA for this request's nonce"
                       : "NVIDIA NRAS verdict: false")
    }

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return base64URLDecode(String(parts[1])).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    // MARK: Key check

    public enum KeyCheck: Sendable, Equatable { case valid, rejected, noCredits, unchecked }

    /// Asks NEAR whether `key` works (POST /v1/check_api_key). Sends the key only, never a prompt.
    /// `unchecked`: no clear answer (offline, busy, a server error).
    public func checkKey(_ key: String) async -> KeyCheck {
        var req = URLRequest(url: Self.base.appending(path: "check_api_key"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await session.data(for: req) else { return .unchecked }
        let (data, resp) = result
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            let valid = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["valid"] as? Bool
            return valid == false ? .rejected : .valid
        case 401, 403: return .rejected
        case 402: return .noCredits
        default: return .unchecked
        }
    }

    // MARK: Completions

    /// One non-streamed completion. Returns the exact response bytes; `body` is kept by the caller byte for byte,
    /// because the enclave signs SHA-256 of both.
    public func complete(body: Data, key: String, on tls: GatewayConnection? = nil) async throws -> (Data, GatewayConnection.Use?) {
        var req = URLRequest(url: Self.base.appending(path: "chat/completions"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("true", forHTTPHeaderField: "x-no-aliasing")
        if let tls {
            let (data, resp, use) = try await tls.data(for: req)
            try Self.ok(resp, data)
            return (data, use)
        }
        let (data, resp) = try await session.data(for: req)
        try Self.ok(resp, data)
        return (data, nil)
    }

    /// The signature for a completion, retried briefly while the gateway records it. nil when none is available.
    public func signature(id: String, key: String) async -> ResponseSignature? {
        var c = URLComponents(url: Self.base.appending(path: "signature/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "signing_algo", value: "ecdsa")]
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600 * attempt)) }
            guard let data = try? await get(c.url!, headers: ["Authorization": "Bearer \(key)"], timeout: 20) else { continue }
            if let s = ResponseSignature(json: data) { return s }
        }
        return nil
    }

    // MARK: HTTP

    func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        try Self.ok(resp, data)
        return data
    }

    static func ok(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { j in
                (j["error"] as? [String: Any])?["message"] as? String ?? j["message"] as? String ?? j["detail"] as? String
            }) ?? ""
            throw Failure.http(code, msg)
        }
    }
}

/// Evidence checked before any prompt is sent: a fresh nonce, the gateway report and every NEAR model candidate.
public struct Preflight: Sendable {
    public let model: String
    public let nonce: String
    public let fetchedAt: Date
    public let bundle: AttestationBundle
    public let checks: [CloudProof.Check]
    /// The watched connection the report was read on; prompts go on it too.
    public var connection: GatewayConnection? = nil
    public var attestationUse: GatewayConnection.Use? = nil
    public var handshakesAtFetch = 0

    /// Every check passed, so prompts may go to this deployment.
    public var passed: Bool { !checks.contains { $0.status == .fail } && bundle.models.count > 0 }
    /// NVIDIA gave its verdict on every model's GPUs. Only NRAS verifies the GPU evidence itself, so a missing verdict
    /// (NRAS unreachable) shows as not checked and still keeps the prompt on the device.
    public var gpuVerdicts: Bool { !checks.contains { $0.id.hasPrefix("model") && $0.id.hasSuffix(".nras") && $0.status != .pass } }
    /// Signers of model candidates that passed every check (docs: verify every candidate, keep the verified ones).
    public var verifiedModelSigners: [String] {
        bundle.models.enumerated().compactMap { i, m in
            checks.filter { $0.id.hasPrefix("model\(i).") }.allSatisfy { $0.status != .fail } ? m.signingAddress : nil
        }
    }
    public var gatewaySigner: String { bundle.gateway.signingAddress }

    /// Fetches and checks evidence for `model`. `remote` also asks NVIDIA NRAS for the GPU verdict.
    public static func run(model: String, cloud: NearAICloud = NearAICloud(), remote: Bool = true, bindTLS: Bool = true) async throws -> Preflight {
        let nonce = AttestationVerifier.newNonce()
        let tls = bindTLS ? GatewayConnection() : nil
        let (_, bundle, use) = try await cloud.attestation(model: model, nonce: nonce, tls: tls)
        var nvidia: [Int: (Bool?, String)] = [:]
        if remote {
            await withTaskGroup(of: (Int, (Bool?, String)).self) { g in
                for (i, m) in bundle.models.enumerated() {
                    if let p = m.nvidiaPayload {
                        g.addTask { let v = await cloud.nvidiaVerdict(p, nonce: nonce); return (i, (v.ok, v.detail)) }
                    }
                }
                for await (i, v) in g { nvidia[i] = v }
            }
        }
        var p = evaluate(model: model, nonce: nonce, bundle: bundle, nvidia: nvidia, at: Date(), peerSPKI: tls.map { $0.handshakes })
        p.connection = tls; p.attestationUse = use; p.handshakesAtFetch = tls?.handshakes.count ?? 0
        return p
    }

    /// The checks for evidence already fetched (tests use recorded reports).
    /// `peerSPKI`: SPKI hashes seen at the TLS handshakes of the connection the report came on (nil: not watched).
    public static func evaluate(model: String, nonce: String, bundle: AttestationBundle, nvidia: [Int: (Bool?, String)] = [:],
                                at date: Date = Date(), peerSPKI: [String]? = nil) -> Preflight {
        var checks = AttestationVerifier.checks(bundle.gateway, nonce: nonce, group: CloudProof.gatewayGroup, at: date)
        if let peers = peerSPKI {
            let fp = bundle.gateway.tlsFingerprint?.lowercased()
            let ok = fp != nil && peers.count == 1 && peers[0] == fp
            checks.append(.init(id: "gw.tls", group: CloudProof.gatewayGroup, title: "This connection ends at the key the quote binds",
                                detail: fp == nil ? "No TLS fingerprint in the report" : peers.isEmpty ? "No TLS handshake seen"
                                    : ok ? "Server certificate key SHA-256 \(fp!.prefix(16)), read on the same connection" : "Server key \(peers.last!.prefix(16)) is not the attested \(fp!.prefix(16))",
                                status: ok ? .pass : .fail))
        }
        if bundle.models.isEmpty {
            checks.append(.init(id: "model.present", group: CloudProof.modelGroup, title: "Model enclave evidence returned", detail: "None for \(model)", status: .fail))
        }
        for (i, m) in bundle.models.enumerated() {
            let prefix = "model\(i)."
            var list = AttestationVerifier.checks(m, nonce: nonce, group: CloudProof.modelGroup, at: date).map { c -> CloudProof.Check in
                var c = c; c.id = prefix + c.id.dropFirst("model.".count); return c
            }
            list.insert(.init(id: prefix + "name", group: CloudProof.modelGroup, title: "Evidence is for the requested model",
                              detail: m.modelName ?? "unnamed", status: m.modelName == model ? .pass : .fail), at: 0)
            if m.nvidiaPayload != nil {
                let v = nvidia[i]
                let status: CloudProof.Status
                switch v?.0 { case .some(true): status = .pass; case .some(false): status = .fail; default: status = .skipped }
                list.append(.init(id: prefix + "nras", group: CloudProof.modelGroup, title: "GPUs attested by NVIDIA",
                                  detail: v?.1 ?? "Not asked", status: status, source: v == nil ? .none : .remote))
            }
            checks += list
        }
        return Preflight(model: model, nonce: nonce, fetchedAt: date, bundle: bundle, checks: checks)
    }

    /// What the phone can't check on its own, listed so nobody reads more into the proof than it says.
    public static let notChecked: [CloudProof.Check] = [
        .init(id: "nc.tcb", group: "Not checked on \(CloudDevice.here)", title: "Intel TCB level and revocation",
              detail: "Needs Intel's collateral (TCB info, QE identity, CRLs). near/verify-attestation.py checks it with dcap-qvl", status: .skipped, source: .none),
        .init(id: "nc.provenance", group: "Not checked on \(CloudDevice.here)", title: "Image provenance of the containers",
              detail: "The compose hash is bound to the quote; who built each image is not checked", status: .skipped, source: .none),
        .init(id: "nc.hop", group: "Not checked on \(CloudDevice.here)", title: "Gateway to model hop for this request",
              detail: "TLS binding covers the \(CloudDevice.noun)-to-gateway connection. NEAR doesn't yet prove which model instance served a request", status: .skipped, source: .none),
    ]

    /// The proof for a reply. `signed` is how many completions carried a verified model-enclave signature.
    public func proof(completions: Int, signed: Int, kind: String?, replyChecks: [CloudProof.Check]) -> CloudProof {
        CloudProof(model: model, tee: AttestationVerifier.teeName(bundle.models), nonce: nonce, fetchedAt: fetchedAt, repliedAt: Date(),
                   signatureKind: kind, modelSigner: bundle.models.first?.signingAddress, gatewaySigner: gatewaySigner,
                   measurements: bundle.models.first.map(AttestationVerifier.measurements) ?? [],
                   checks: replyChecks + checks + Self.notChecked, completions: completions, signedCompletions: signed)
    }
}

/// Free Private Cloud messages per device per day on Hermit's shared key. Your own key has no limit here.
public enum SharedQuota {
    public static let perDay = 30
    static let dayKey = "hermit.cloud.shared.day", countKey = "hermit.cloud.shared.count"
    static var today: String { ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate]) }
    public static var used: Int {
        UserDefaults.standard.string(forKey: dayKey) == today ? UserDefaults.standard.integer(forKey: countKey) : 0
    }
    public static var left: Int { max(perDay - used, 0) }
    /// One message spent. Called once a completion has come back, so a failed request costs nothing.
    static func consume() {
        let d = UserDefaults.standard
        d.set(used + 1, forKey: countKey); d.set(today, forKey: dayKey)
    }
}
