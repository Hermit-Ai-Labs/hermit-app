import Foundation
import HermitCore

/// Private Cloud runs the same toolbox as the on-device model (HermitCore.AgentToolbox).
public typealias CloudToolbox = AgentToolbox

/// The agent tools: all 30 of hermit_tools_v3.json (OpenAI `tools` format), the registry the next on-device model is
/// trained on. Cloud models get every tool; packs are only for the phone's small prompt.
public enum CloudTools {
    public static let schemaData: Data = {
        guard let url = Bundle.module.url(forResource: "hermit_tools_v3", withExtension: "json"), let d = try? Data(contentsOf: url) else { return Data("[]".utf8) }
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
    /// The cloud system prompt (hermit-lab/train/spec/CLOUD_SYSTEM_v3.md, from "You are Hermit" on), as shipped.
    static let baseSystemPrompt: String = {
        guard let url = Bundle.module.url(forResource: "cloud_system_v3", withExtension: "txt"), let t = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// What is sent if the bundled prompt can't be read: the rules that matter most, in short.
    static let fallbackSystemPrompt = """
        You are Hermit, the assistant inside a self-custody crypto wallet app. You run on a cloud model in this session; the wallet \
        keys and every approval stay on the user's device. Use the tools instead of guessing and never invent prices or balances. \
        The prepare_ tools only open a review screen that the user approves with Face ID. Never say a trade, swap or transfer \
        happened; say it is ready for review. Tools that show a card are not done until the user taps it.
        Keep answers short and plain: a few sentences, simple words, no filler. Do not use middle dots as separators. \
        If you don't know something, say so.
        """

    /// The prompt with this device's biometric word. It is written with "Face ID" ("Touch ID on a Mac" where it explains
    /// both); a Mac reads "Touch ID" throughout, the word its tool results use.
    static func deviceText(_ text: String, bio: String) -> String {
        guard bio != "Face ID" else { return text }
        return text.replacingOccurrences(of: "Face ID (Touch ID on a Mac)", with: bio).replacingOccurrences(of: "Face ID", with: bio)
    }

    public static func systemPrompt(name: String, memory: [String]) -> String {
        var s = deviceText(baseSystemPrompt.isEmpty ? fallbackSystemPrompt : baseSystemPrompt, bio: ToolChat.bioWord)
        // Where this session runs, for "where do you run?": true of Private Cloud only, so it isn't in the shared prompt.
        s += """
        \n\nThis session is Hermit's Private Cloud: you run on NEAR AI Cloud, inside a hardware enclave (Intel TDX with NVIDIA \
        confidential GPUs) that the user's \(CloudDevice.noun) verified before sending this. Hermit keeps the chat on the \
        \(CloudDevice.noun) and has no server of its own.
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
                    // NEAR retires and renames models; a saved one that's gone answers 400. Switch to one that's listed.
                    if case .http(400, _)? = error as? NearAICloud.Failure, let next = await Self.replacement(for: model, cloud: cloud) {
                        NearAICloud.model = next.id
                        cont.yield(.text("\(model.split(separator: "/").last.map(String.init) ?? model) is no longer on NEAR AI Cloud, so Private Cloud now uses \(next.name). Your message stayed on \(CloudDevice.here). Send it again."))
                        return
                    }
                    cont.yield(.text("I couldn't reach NEAR AI Cloud to check its enclave, so your message stayed on \(CloudDevice.here). \(Self.describe(error))"))
                    return
                }
                guard pre.passed else {
                    cont.yield(.steps(0))
                    let failed = pre.checks.filter { $0.status == .fail }.map(\.title)
                    cont.yield(.text("I didn't send your message. The enclave's evidence failed: \(failed.prefix(3).joined(separator: ", ")). Nothing left \(CloudDevice.here)."))
                    cont.yield(.proof(pre.proof(completions: 0, signed: 0, kind: nil, replyChecks: [])))
                    await state.clearPreflight()
                    return
                }
                // Only NVIDIA's service verifies the GPU evidence itself: without its verdict nothing is sent.
                guard pre.gpuVerdicts else {
                    cont.yield(.steps(0))
                    cont.yield(.text("I couldn't get NVIDIA's verdict on the enclave's GPUs, so I didn't send your message. Nothing left \(CloudDevice.here). Try again in a moment."))
                    cont.yield(.proof(pre.proof(completions: 0, signed: 0, kind: nil, replyChecks: [])))
                    pre.connection?.invalidate()
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
                await run(prompt: prompt, model: model, key: key, shared: NearAICloud.usesSharedKey, preflight: pre, cont: cont)
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// A model id that's no longer listed: the default model, or the first listed one. nil when it's still listed or the
    /// list can't be read.
    static func replacement(for model: String, cloud: NearAICloud) async -> NearAICloud.Model? {
        guard let list = try? await cloud.models(), !list.isEmpty, !list.contains(where: { $0.id == model }) else { return nil }
        return list.first { $0.id == NearAICloud.defaultModel } ?? list[0]
    }

    /// `shared`: the message goes out on Hermit's shared key, so it counts toward today's free messages once a
    /// completion comes back (a failed request costs none).
    private func run(prompt: String, model: String, key: String, shared: Bool, preflight pre: Preflight, cont: AsyncStream<AgentEvent>.Continuation) async {
        await state.append(["role": "user", "content": prompt])
        cont.yield(.status("Thinking in the enclave…"))
        var steps = 0, actions: [Action] = []
        var cards: [Card] = []          // confirm cards (cancel, contact, automation, reminder): one tap each, no money
        var turnResults: [String] = []  // what tools returned while answering this message
        var signatures: [Task<SignedCheck, Never>] = []
        var uses: [GatewayConnection.Use?] = []
        var finalText = ""
        var cut = false
        var counted = false
        do {
            for round in 0..<Self.maxRounds {
                try Task.checkCancellation()
                let body = try await state.body(model: model, tools: toolbox == nil || round == Self.maxRounds - 1 ? nil : CloudTools.schemaData)
                let (raw, use) = try await cloud.complete(body: body, key: key, on: pre.connection)
                uses.append(use)
                if shared && !counted { SharedQuota.consume(); counted = true }
                guard let reply = Self.completion(raw) else {
                    throw NearAICloud.Failure.bad("NEAR AI Cloud sent a reply I couldn't read.")
                }
                let id = reply.id, msg = reply.message
                let cloud = self.cloud
                signatures.append(Task { await Self.checkSignature(cloud: cloud, id: id, key: key, request: body, response: raw, model: model, preflight: pre) })
                let calls = (msg["tool_calls"] as? [[String: Any]]) ?? []
                if calls.isEmpty || toolbox == nil {
                    finalText = Self.clean(msg["content"] as? String ?? "")
                    cut = reply.finish == "length"
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
                    // The same guards as on the device: a transfer, a contact or a payment reminder only takes an address the
                    // user typed in this chat (or a saved contact's, looked up by name), a mint must be the user's or a
                    // search's, and an automation only comes from the user's own message.
                    let out: ToolOutcome
                    if let refusal = ToolGuard.refusal(name, arguments: parsed, userText: await state.userText(), session: await state.toolSession()) {
                        out = ToolOutcome(content: refusal)
                    } else if name == "create_automation", let refusal = ToolGuard.automationRefusal(parsed, turn: prompt, toolResults: turnResults) {
                        out = ToolOutcome(content: refusal)
                    } else if name == "prepare_multisend", let refusal = ToolGuard.multisendRefusal(parsed, userTextWithFiles: await state.userTextWithFiles()) {
                        out = ToolOutcome(content: refusal)
                    } else if let box = self.toolbox {
                        out = await box.run(name, arguments: args)
                        await state.note(name, argumentsJSON: args, result: out.content)
                    } else {
                        out = ToolOutcome(content: #"{"error":"no tools"}"#)
                    }
                    if let a = out.action { ToolChat.add(a, to: &actions) }
                    if let c = out.card, !cards.contains(c) { cards.append(c) }
                    let cleaned = ToolResult.clean(out.content, plainDecimals: true)
                    turnResults.append(cleaned)
                    await state.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": cleaned])
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
        if finalText.isEmpty && !cut {
            finalText = !actions.isEmpty ? "Ready for your review." : !cards.isEmpty ? "The card is below. Nothing happens until you tap it."
                : "I didn't get an answer back. Try again."
        }
        // The reply ran into the token limit: say so instead of ending mid-sentence as if it were done.
        if cut { finalText += (finalText.isEmpty ? "" : "\n\n") + "That reply hit the length limit. Ask me to continue." }
        // Text appears at a reading pace; the full reply has already arrived.
        cont.yield(.block(.text("")))
        for word in finalText.split(separator: " ", omittingEmptySubsequences: false) {
            if Task.isCancelled { return }
            cont.yield(.text(String(word) + " "))
            try? await Task.sleep(for: .milliseconds(12))
        }
        cont.yield(.status("Checking the reply's signature…"))
        var results: [SignedCheck] = []
        for t in signatures { results.append(await t.value) }
        // Review buttons and confirm cards only for a reply the attested model enclave signed (money still needs the
        // review and biometrics; a card still needs the user's tap).
        if !actions.isEmpty || !cards.isEmpty {
            if !results.isEmpty && results.allSatisfy(\.modelSigned) {
                for c in cards { cont.yield(.block(.card(c))) }
                if !actions.isEmpty { cont.yield(.block(.actions(actions))) }
            } else { cont.yield(.block(.text("The reply's signature didn't verify, so I left out its review buttons. Try again."))) }
        }
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
            .init(id: "reply.pre", group: g, title: "Enclave checked before the prompt left \(CloudDevice.here)",
                  detail: "Evidence fetched \(Int(Date().timeIntervalSince(pre.fetchedAt)))s before this reply", status: .pass),
            .init(id: "reply.sig", group: g, title: n == 1 ? "Reply signed by the enclave" : "All \(n) completions signed by the enclave",
                  detail: available ? (kinds == ["provider_tee"] ? "Signed by the model enclave" : "Kinds: \(kinds.sorted().joined(separator: ", "))")
                                    : (sigs.first { !$0.available }?.detail ?? ""), status: st(available && n > 0)),
            .init(id: "reply.bytes", group: g, title: "Signature covers the exact request and response bytes",
                  detail: "SHA-256 of what \(CloudDevice.here) sent and received", status: available ? st(sigs.allSatisfy(\.textMatches)) : .skipped),
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

    /// A completion's id, its first message and why it stopped ("stop", "tool_calls", "length"...).
    static func completion(_ raw: Data) -> (id: String, message: [String: Any], finish: String?)? {
        guard let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = j["id"] as? String,
              let choice = (j["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any] else { return nil }
        return (id, msg, choice["finish_reason"] as? String)
    }

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
        if (e as? URLError)?.code == .notConnectedToInternet { return "\(CloudDevice.capitalHere) is offline. On-device mode still works." }
        return e.localizedDescription
    }
}

/// The conversation and the checked evidence. Only in memory.
actor CloudState {
    private var history: [[String: Any]] = []
    private var instructions = NearCloudAgent.systemPrompt(name: "", memory: [])
    private(set) var preflight: Preflight?
    /// What this chat's own tools returned that later calls rely on (a contact's address, searched mints).
    private var session = ToolSession()

    func reset() { history = []; preflight = nil; session = ToolSession() }
    func toolSession() -> ToolSession { session }
    func note(_ name: String, argumentsJSON: String, result: String) { session.note(name, argumentsJSON: argumentsJSON, result: result) }
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
                                "stream": false, "max_tokens": 4096, "temperature": 0.6]
        // Qwen models on NEAR reason by default, and the reasoning is billed against max_tokens: chat answers without it
        // (docs.near.ai/cloud/reasoning-models). Part of this one body, so the signed hash still covers it.
        if model.hasPrefix("Qwen/") { b["chat_template_kwargs"] = ["enable_thinking": false] }
        if let tools, let t = try? JSONSerialization.jsonObject(with: tools) { b["tools"] = t; b["tool_choice"] = "auto" }
        guard JSONSerialization.isValidJSONObject(b) else { throw NearAICloud.Failure.bad("Couldn't build the request.") }
        return try JSONSerialization.safeData(withJSONObject: b, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
