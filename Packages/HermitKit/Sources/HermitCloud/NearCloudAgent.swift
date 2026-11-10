import Foundation
import HermitCore

/// Private Cloud runs the same toolbox as the on-device model (HermitCore.AgentToolbox).
public typealias CloudToolbox = AgentToolbox

/// The agent tools, the same schema the on-device Hermit model is trained on (hermit_tools.json, OpenAI `tools` format).
public enum CloudTools {
    public static let schemaData: Data = {
        guard let url = Bundle.module.url(forResource: "hermit_tools", withExtension: "json"), let d = try? Data(contentsOf: url) else { return Data("[]".utf8) }
        return d
    }()
    public static var names: [String] {
        ((try? JSONSerialization.jsonObject(with: schemaData) as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }
    /// Shown while a tool runs.
    public static func status(_ name: String, arguments: [String: Any] = [:]) -> String { ToolStatus.label(name, arguments: arguments) }
}

/// Hermit on NEAR AI Cloud. Before each prompt leaves the phone, the deployment's attestation is fetched with a fresh
/// nonce and checked here; if any check fails nothing is sent. Every completion's signature is then checked against
/// the attested model key. The conversation lives only in this object, on the phone, until New chat.
public final class NearCloudAgent: Agent, @unchecked Sendable {
    public static func systemPrompt(name: String, memory: [String]) -> String {
        var s = """
        You are Hermit, a private AI assistant. Right now you run in Hermit's Private Cloud mode: on NEAR AI Cloud, inside a \
        hardware enclave (Intel TDX with NVIDIA confidential GPUs) that the user's phone verified before sending this. \
        Hermit keeps the chat on the phone and has no server of its own.
        You can use tools for prices, the user's balances and Hyperliquid account, maths, markets and yields. Use them instead of guessing; \
        never invent prices or balances. The prepare_ tools only open a review screen: the user approves with Face ID. \
        Never say a trade, swap or transfer happened; say it is ready for review.
        Keep answers short and plain: a few sentences, simple words, no filler. Do not use middle dots as separators. \
        If you don't know something, say so.
        """
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { s += "\nThe user wants to be called \(name)." }
        var notes: [String] = [], used = 0
        for line in memory where used + line.count < 2000 { notes.append("- " + line); used += line.count }
        if !notes.isEmpty { s += "\nThe user's standing notes (hermit.md). Follow them:\n" + notes.joined(separator: "\n") }
        return s
    }

    let cloud: NearAICloud
    let toolbox: CloudToolbox?
    private let state = CloudState()
    /// How long checked evidence is reused within one chat before a fresh nonce is sent.
    /// Fresh evidence for every reply: the report and the prompt then share one live TLS connection. 0 means never reuse.
    public static let evidenceMaxAge: TimeInterval = 0
    static let maxRounds = 5

    public init(cloud: NearAICloud = NearAICloud(), toolbox: CloudToolbox? = nil) {
        self.cloud = cloud; self.toolbox = toolbox
    }

    public func reset() { Task { [state] in await state.reset() } }
    public func setContext(name: String, memory: [String]) {
        let s = Self.systemPrompt(name: name, memory: memory)
        Task { [state] in await state.setInstructions(s) }
    }

    /// Fresh or recent evidence for `model`, checked.
    public func preflight(model: String, force: Bool = false) async throws -> Preflight {
        if !force, let p = await state.preflight, p.model == model, Date().timeIntervalSince(p.fetchedAt) < Self.evidenceMaxAge, p.passed { return p }
        await state.preflight?.connection?.invalidate()
        let p = try await Preflight.run(model: model, cloud: cloud)
        await state.setPreflight(p)
        return p
    }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            let task = Task { [self] in
                defer { cont.finish() }
                let model = NearAICloud.model
                cont.yield(.status("Checking the enclave…"))
                let pre: Preflight
                do { pre = try await preflight(model: model) } catch {
                    cont.yield(.steps(0))
                    cont.yield(.text("I couldn't reach NEAR AI Cloud to check its enclave, so your message stayed on this phone. \(Self.describe(error))"))
                    return
                }
                guard pre.passed else {
                    cont.yield(.steps(0))
                    let failed = pre.checks.filter { $0.status == .fail }.map(\.title)
                    cont.yield(.text("I didn't send your message. The enclave's evidence failed: \(failed.prefix(3).joined(separator: ", ")). Nothing left this phone."))
                    cont.yield(.proof(pre.proof(completions: 0, signed: 0, kind: nil, replyChecks: [])))
                    await state.clearPreflight()
                    return
                }
                guard let key = NearAICloud.apiKey else {
                    cont.yield(.steps(0))
                    cont.yield(.text(NearAICloud.usesSharedKey
                        ? "The enclave checks out, but today's \(SharedQuota.perDay) free Private Cloud messages are used up, so I didn't send your message. Add your own NEAR AI Cloud key in Settings, Private Cloud, or switch to On-device."
                        : "The enclave checks out (tap Enclave verified below to see every check), but there's no NEAR AI Cloud API key yet, so I didn't send your message. Add one in Settings, Private Cloud."))
                    cont.yield(.proof(pre.proof(completions: 0, signed: 0, kind: nil, replyChecks: [])))
                    return
                }
                if NearAICloud.usesSharedKey { SharedQuota.consume() }
                await run(prompt: prompt, model: model, key: key, preflight: pre, cont: cont)
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func run(prompt: String, model: String, key: String, preflight pre: Preflight, cont: AsyncStream<AgentEvent>.Continuation) async {
        await state.append(["role": "user", "content": prompt])
        cont.yield(.status("Thinking in the enclave…"))
        var steps = 0, actions: [Action] = []
        var signatures: [Task<SignedCheck, Never>] = []
        var uses: [GatewayConnection.Use?] = []
        var finalText = ""
        do {
            for round in 0..<Self.maxRounds {
                try Task.checkCancellation()
                let body = try await state.body(model: model, tools: toolbox == nil || round == Self.maxRounds - 1 ? nil : CloudTools.schemaData)
                let (raw, use) = try await cloud.complete(body: body, key: key, on: pre.connection)
                uses.append(use)
                guard let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = j["id"] as? String,
                      let msg = ((j["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
                    throw NearAICloud.Failure.bad("NEAR AI Cloud sent a reply I couldn't read.")
                }
                let cloud = self.cloud
                signatures.append(Task { await Self.checkSignature(cloud: cloud, id: id, key: key, request: body, response: raw, model: model, preflight: pre) })
                let calls = (msg["tool_calls"] as? [[String: Any]]) ?? []
                if calls.isEmpty || toolbox == nil {
                    finalText = Self.clean(msg["content"] as? String ?? "")
                    await state.append(["role": "assistant", "content": finalText])
                    break
                }
                var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls]
                assistant["content"] = (msg["content"] as? String).map { $0 as Any } ?? NSNull()
                await state.append(assistant)
                for call in calls {
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? ""
                    // As on the device: a send's chain the user never named is left for the toolbox to work out.
                    let args = ToolGuard.adjusted(name, argumentsJSON: fn?["arguments"] as? String ?? "{}", userText: await state.userText())
                    let parsed = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
                    cont.yield(.status(CloudTools.status(name, arguments: parsed) + "…"))
                    steps += 1
                    // The same guard as on the device: a transfer only goes to an address the user typed in this chat.
                    let out: ToolOutcome
                    if let refusal = ToolGuard.refusal(name, arguments: parsed, userText: await state.userText()) {
                        out = ToolOutcome(content: refusal)
                    } else if name == "prepare_multisend", let refusal = ToolGuard.multisendRefusal(parsed, userTextWithFiles: await state.userTextWithFiles()) {
                        out = ToolOutcome(content: refusal)
                    } else {
                        out = await toolbox?.run(name, arguments: args) ?? ToolOutcome(content: #"{"error":"no tools"}"#)
                    }
                    if let a = out.action { actions.append(a) }
                    await state.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": ToolResult.clean(out.content)])
                }
                cont.yield(.status("Thinking in the enclave…"))
            }
        } catch is CancellationError {
            return
        } catch {
            cont.yield(.steps(steps))
            cont.yield(.text("Private Cloud stopped: \(Self.describe(error))"))
            await state.dropLastUser()
            return
        }
        cont.yield(.steps(steps))
        if finalText.isEmpty { finalText = actions.isEmpty ? "I didn't get an answer back. Try again." : "Ready for your review." }
        // Text appears at a reading pace; the full reply has already arrived.
        cont.yield(.block(.text("")))
        for word in finalText.split(separator: " ", omittingEmptySubsequences: false) {
            if Task.isCancelled { return }
            cont.yield(.text(String(word) + " "))
            try? await Task.sleep(for: .milliseconds(12))
        }
        if !actions.isEmpty { cont.yield(.block(.actions(actions))) }

        cont.yield(.status("Checking the reply's signature…"))
        var results: [SignedCheck] = []
        for t in signatures { results.append(await t.value) }
        cont.yield(.steps(steps))
        cont.yield(.proof(Self.proof(pre, results, tls: Self.tlsCheck(pre, uses))))
    }

    // MARK: Signatures

    struct SignedCheck: Sendable {
        var available = false
        var kind: String?
        var textMatches = false
        var signerMatches = false
        var detail = ""
        var modelSigned: Bool { available && kind == "provider_tee" && textMatches && signerMatches }
    }

    static func checkSignature(cloud: NearAICloud, id: String, key: String, request: Data, response: Data, model: String, preflight: Preflight) async -> SignedCheck {
        var r = SignedCheck()
        guard let sig = await cloud.signature(id: id, key: key) else { r.detail = "No signature available for \(id)"; return r }
        r.available = true; r.kind = sig.kind
        let isModel = sig.kind == "provider_tee"
        guard isModel || sig.kind == "gateway" else { r.detail = "Unknown signature kind \(sig.kind ?? "none")"; return r }
        let expected = ResponseSignature.expectedText(request: request, response: response, model: isModel ? model : nil)
        r.textMatches = sig.text == expected
        // provider_tee: the signer must match exactly one verified model candidate; gateway: the verified gateway.
        let candidates = isModel ? preflight.verifiedModelSigners.filter { $0.lowercased() == sig.signingAddress.lowercased() } : [preflight.gatewaySigner]
        guard candidates.count == 1, let signer = candidates.first else {
            r.detail = "Signer \(sig.signingAddress) matches \(candidates.count) verified reports"; return r
        }
        switch sig.verify(expectedText: expected, expectedSigner: signer, expectedAlgo: "ecdsa") {
        case .verified: r.signerMatches = true; r.detail = "Recovered \(AttestationVerifier.short(signer))"
        case .textMismatch: r.detail = "Signed text is for other bytes"
        case .badSignature: r.detail = "Signature doesn't verify"
        case .signerMismatch(let rec): r.detail = "Recovered \(AttestationVerifier.short(rec)), not the attested key"
        case .unsupported(let s): r.detail = "Unsupported: \(s)"
        }
        return r
    }

    /// Every completion went over the connection the attestation was read on, with no new TLS handshake since.
    static func tlsCheck(_ pre: Preflight, _ uses: [GatewayConnection.Use?]) -> CloudProof.Check? {
        guard let conn = pre.connection, pre.checks.contains(where: { $0.id == "gw.tls" && $0.status == .pass }) else { return nil }
        let first = pre.attestationUse?.connection
        let same = first != nil && !uses.isEmpty && uses.allSatisfy { $0?.connection == first && $0?.reused == true }
        let handshakes = conn.handshakes
        let noNew = handshakes.count == pre.handshakesAtFetch
        let detail: String
        let status: CloudProof.Status
        if same && noNew { status = .pass; detail = "One connection for the attestation and the prompt, no new handshake" }
        else if handshakes.allSatisfy({ $0 == handshakes.first }) { status = .skipped; detail = "The connection was re-opened. The new one showed the same attested key, which NEAR counts as inconclusive" }
        else { status = .fail; detail = "A different server key was seen on this session" }
        return .init(id: "reply.tls", group: CloudProof.replyGroup, title: "Prompt sent on that same verified connection", detail: detail, status: status)
    }

    static func proof(_ pre: Preflight, _ sigs: [SignedCheck], tls: CloudProof.Check? = nil) -> CloudProof {
        let n = sigs.count, model = sigs.filter(\.modelSigned).count
        let kinds = Set(sigs.compactMap(\.kind))
        let g = CloudProof.replyGroup
        func st(_ ok: Bool) -> CloudProof.Status { ok ? .pass : .fail }
        let available = sigs.allSatisfy(\.available)
        var checks: [CloudProof.Check] = [
            .init(id: "reply.pre", group: g, title: "Enclave checked before the prompt left the phone",
                  detail: "Evidence fetched \(Int(Date().timeIntervalSince(pre.fetchedAt)))s before this reply", status: .pass),
            .init(id: "reply.sig", group: g, title: n == 1 ? "Reply signed by the enclave" : "All \(n) completions signed by the enclave",
                  detail: available ? (kinds == ["provider_tee"] ? "Signed by the model enclave" : "Kinds: \(kinds.sorted().joined(separator: ", "))")
                                    : (sigs.first { !$0.available }?.detail ?? ""), status: st(available && n > 0)),
            .init(id: "reply.bytes", group: g, title: "Signature covers the exact request and response bytes",
                  detail: "SHA-256 of what this phone sent and received", status: available ? st(sigs.allSatisfy(\.textMatches)) : .skipped),
            .init(id: "reply.signer", group: g, title: "Signer is the attested model key",
                  detail: sigs.first { !$0.signerMatches }?.detail ?? sigs.first?.detail ?? "",
                  status: available ? st(sigs.allSatisfy(\.signerMatches) && kinds == ["provider_tee"]) : .skipped),
        ]
        if let tls { checks.insert(tls, at: 1) }
        if kinds.contains("gateway") {
            checks.append(.init(id: "reply.gw", group: g, title: "Some completions were signed by the gateway, not the model",
                                detail: "A gateway signature doesn't prove which model wrote the bytes", status: .fail))
        }
        return pre.proof(completions: n, signed: model, kind: kinds.count == 1 ? kinds.first : (kinds.isEmpty ? nil : "mixed"), replyChecks: checks)
    }

    // MARK: Helpers

    /// Drops any reasoning block and middle-dot separators.
    static func clean(_ s: String) -> String {
        var t = s
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) { t.removeSubrange(open.lowerBound..<close.upperBound) }
            else { t.removeSubrange(open.lowerBound..<t.endIndex) }
        }
        if let stray = t.range(of: "</think>") { t.removeSubrange(t.startIndex..<stray.upperBound) }
        return t.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "·", with: ",").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ e: Error) -> String {
        if let f = e as? NearAICloud.Failure { return f.description }
        if (e as? URLError)?.code == .notConnectedToInternet { return "This phone is offline. On-device mode still works." }
        return e.localizedDescription
    }
}

/// The conversation and the checked evidence. Only in memory.
actor CloudState {
    private var history: [[String: Any]] = []
    private var instructions = NearCloudAgent.systemPrompt(name: "", memory: [])
    private(set) var preflight: Preflight?

    func reset() { history = []; preflight = nil }
    func setInstructions(_ s: String) { instructions = s }
    func setPreflight(_ p: Preflight) { preflight = p }
    func clearPreflight() { preflight = nil }
    func append(_ m: [String: Any]) { history.append(m) }
    func userText() -> String {
        history.compactMap { $0["role"] as? String == "user" ? $0["content"] as? String : nil }
            .map(ToolChat.withoutFiles).joined(separator: "\n")
    }
    func userTextWithFiles() -> String {
        history.compactMap { $0["role"] as? String == "user" ? $0["content"] as? String : nil }.joined(separator: "\n")
    }
    func dropLastUser() { if let i = history.lastIndex(where: { $0["role"] as? String == "user" }) { history.removeSubrange(i...) } }

    /// The request body, built once: these exact bytes are sent and hashed.
    func body(model: String, tools: Data?) throws -> Data {
        var b: [String: Any] = ["model": model, "messages": [["role": "system", "content": instructions]] + history,
                                "stream": false, "max_tokens": 1200, "temperature": 0.6]
        if let tools, let t = try? JSONSerialization.jsonObject(with: tools) { b["tools"] = t; b["tool_choice"] = "auto" }
        guard JSONSerialization.isValidJSONObject(b) else { throw NearAICloud.Failure.bad("Couldn't build the request.") }
        return try JSONSerialization.safeData(withJSONObject: b, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
