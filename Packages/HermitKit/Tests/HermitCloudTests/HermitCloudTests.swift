import XCTest
import CryptoKit
import HermitCore
@testable import HermitCloud

/// Real attestation reports recorded from cloud-api.near.ai on 2026-11-08 (no key needed), with the nonce this
/// machine generated for each. Every check must pass on them, and each tampering must be caught.
final class HermitCloudTests: XCTestCase {
    func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func report(_ name: String) throws -> (AttestationBundle, String, Data) {
        let raw = try fixture(name, "json")
        let nonce = String(decoding: try fixture(name, "nonce"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (try AttestationBundle(json: raw), nonce, raw)
    }
    /// The recorded certificates are in date now; pin the clock so the tests don't expire with them.
    let recorded = ISO8601DateFormatter().date(from: "2026-11-08T09:30:00Z")!

    func testRealReportsPassEveryCheck() throws {
        for (name, model) in [("qwen-report", "Qwen/Qwen3.8-27B"), ("glm-report", "z-ai/glm-5.3-flash")] {
            let (bundle, nonce, _) = try report(name)
            XCTAssertEqual(bundle.models.count, 1)
            let pre = Preflight.evaluate(model: model, nonce: nonce, bundle: bundle, at: recorded)
            let failed = pre.checks.filter { $0.status == .fail }
            XCTAssertTrue(failed.isEmpty, "\(name): \(failed.map { "\($0.id) \($0.detail)" })")
            XCTAssertTrue(pre.passed)
            // Gateway and model each: quote, signature chain, nonce, signer, config, RTMR3, debug.
            for id in ["gw.qsig", "gw.qe", "gw.root", "gw.nonce", "gw.signer", "gw.config", "gw.rtmr3", "gw.debug",
                       "model0.qsig", "model0.qe", "model0.root", "model0.nonce", "model0.signer", "model0.config", "model0.rtmr3",
                       "model0.debug", "model0.gpunonce", "model0.name"] {
                XCTAssertEqual(pre.checks.first { $0.id == id }?.status, .pass, "\(name) \(id)")
            }
            XCTAssertEqual(pre.verifiedModelSigners, [bundle.models[0].signingAddress])
        }
    }

    func testQuoteFieldsMatchDcapQvl() throws {
        // Values printed by dcap-qvl (Phala's Intel DCAP verifier) for the same quote.
        let (bundle, nonce, _) = try report("qwen-report")
        let q = try TDXQuote(bundle.models[0].intelQuote)
        XCTAssertTrue(q.isTDXv4)
        XCTAssertFalse(q.debug)
        XCTAssertEqual(q.reportData.suffix(32).hex, nonce)
        XCTAssertEqual(q.reportData.prefix(20).hex, "835ab53d20294ef795906dff21ae4c045336aa26")
        XCTAssertTrue(q.verifyChain(at: recorded).allPassed)
    }

    func testWrongNonceFails() throws {
        let (bundle, _, _) = try report("qwen-report")
        let pre = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: AttestationVerifier.newNonce(), bundle: bundle, at: recorded)
        XCTAssertFalse(pre.passed)
        for id in ["gw.nonce", "gw.echo", "model0.nonce", "model0.echo", "model0.gpunonce"] {
            XCTAssertEqual(pre.checks.first { $0.id == id }?.status, .fail, id)
        }
    }

    func testWrongModelFails() throws {
        let (bundle, nonce, _) = try report("qwen-report")
        let pre = Preflight.evaluate(model: "z-ai/glm-5.3-flash", nonce: nonce, bundle: bundle, at: recorded)
        XCTAssertEqual(pre.checks.first { $0.id == "model0.name" }?.status, .fail)
        XCTAssertFalse(pre.passed)
    }

    /// Edits the recorded JSON, then re-checks.
    func tampered(_ edit: (inout [String: Any]) -> Void) throws -> Preflight {
        let (_, nonce, raw) = try report("qwen-report")
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        edit(&j)
        let bundle = try AttestationBundle(json: try JSONSerialization.data(withJSONObject: j))
        return Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: recorded)
    }
    func model0(_ j: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var ms = j["model_attestations"] as! [[String: Any]]
        edit(&ms[0]); j["model_attestations"] = ms
    }

    func testSwappedSignerFails() throws {
        let p = try tampered { j in model0(&j) { $0["signing_address"] = "0x" + String(repeating: "ab", count: 20) } }
        XCTAssertEqual(p.checks.first { $0.id == "model0.signer" }?.status, .fail)
    }

    func testEditedComposeFails() throws {
        let p = try tampered { j in model0(&j) { m in
            var info = m["info"] as! [String: Any]
            var tcb = info["tcb_info"] as! [String: Any]
            tcb["app_compose"] = (tcb["app_compose"] as! String) + " "
            info["tcb_info"] = tcb; m["info"] = info
        } }
        XCTAssertEqual(p.checks.first { $0.id == "model0.config" }?.status, .fail)
    }

    func testEditedEventLogFails() throws {
        let p = try tampered { j in model0(&j) { m in
            var log = m["event_log"] as! [[String: Any]]
            let i = log.lastIndex { ($0["imr"] as? Int) == 3 }!
            log[i]["event_payload"] = "00"; log[i]["digest"] = ""
            m["event_log"] = log
        } }
        XCTAssertEqual(p.checks.first { $0.id == "model0.rtmr3" }?.status, .fail)
    }

    func testFlippedQuoteByteFails() throws {
        // One bit in the TD report body (inside RTMR2): the attestation key's signature no longer holds.
        let p = try tampered { j in model0(&j) { m in
            var q = Data(hexString: m["intel_quote"] as! String)!
            q[48 + 300] ^= 1
            m["intel_quote"] = q.hex
        } }
        XCTAssertEqual(p.checks.first { $0.id == "model0.qsig" }?.status, .fail)
    }

    func testGuestOSIsOneNEARPublishes() throws {
        // MRTD, RTMR1 and RTMR2 of the recorded quotes are the values near/verify-attestation.py recomputes from the
        // images in github.com/nearai/dstack-images (its offline run on the same fixture prints them).
        for name in ["qwen-report", "glm-report"] {
            let (bundle, nonce, _) = try report(name)
            let pre = Preflight.evaluate(model: bundle.models[0].modelName ?? "", nonce: nonce, bundle: bundle, at: recorded)
            let gw = try XCTUnwrap(pre.checks.first { $0.id == "gw.os" }), model = try XCTUnwrap(pre.checks.first { $0.id == "model0.os" })
            XCTAssertEqual(gw.status, .pass, name); XCTAssertTrue(gw.detail.hasPrefix("dstack-0.5.12:"), gw.detail)
            XCTAssertEqual(model.status, .pass, name); XCTAssertTrue(model.detail.hasPrefix("dstack-nvidia-0.5.12:"), model.detail)
        }
        // Measurements this build doesn't know are listed as not checked: never passed, and never a failure by themselves.
        let p = try tampered { j in model0(&j) { m in
            var q = Data(hexString: m["intel_quote"] as! String)!
            q[48 + 328 + 96] ^= 1   // one bit of RTMR2
            m["intel_quote"] = q.hex
        } }
        let unknown = try XCTUnwrap(p.checks.first { $0.id == "model0.os" })
        XCTAssertEqual(unknown.status, .skipped); XCTAssertEqual(unknown.source, CloudProof.Source.none)
        XCTAssertEqual(p.checks.first { $0.id == "model0.qsig" }?.status, .fail)   // the edited quote itself is still caught
    }

    func testExpiredCertificatesFail() throws {
        let (bundle, nonce, _) = try report("qwen-report")
        let late = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: Date(timeIntervalSince1970: 2_100_000_000))
        XCTAssertEqual(late.checks.first { $0.id == "model0.root" }?.status, .fail)
    }

    func testTLSBinding() throws {
        // Recorded with include_tls_fingerprint=true; the gateway's fingerprint was the peer key on that connection.
        let (bundle, nonce, _) = try report("qwen-tls-report")
        let fp = try XCTUnwrap(bundle.gateway.tlsFingerprint)
        let good = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: recorded, peerSPKI: [fp])
        XCTAssertTrue(good.passed, "\(good.checks.filter { $0.status == .fail })")
        XCTAssertEqual(good.checks.first { $0.id == "gw.tls" }?.status, .pass)
        XCTAssertEqual(good.checks.first { $0.id == "gw.signer" }?.status, .pass, "report data = SHA-256(signer || fingerprint) || nonce")
        let other = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: recorded, peerSPKI: [String(repeating: "0", count: 64)])
        XCTAssertEqual(other.checks.first { $0.id == "gw.tls" }?.status, .fail)
        let twice = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: recorded, peerSPKI: [fp, fp])
        XCTAssertEqual(twice.checks.first { $0.id == "gw.tls" }?.status, .fail, "two handshakes: not one connection")
    }

    func testIntelRootIsIntels() {
        // SHA-256 of Intel_SGX_Provisioning_Certification_RootCA.cer as published by Intel.
        XCTAssertEqual(Data(SHA256.hash(data: IntelRoot.der)).hex, "44a0196b2b99f889b8e149e95b807a350e7424964399e885a7cbb8ccfab674d3")
    }

    // MARK: Response signatures

    // Signed with eth_account (key 0x11…11) over the text NEAR's model enclave signs.
    let req = Data(#"{"model":"Qwen/Qwen3.8-27B","messages":[]}"#.utf8)
    let resp = Data(#"{"id":"chatcmpl-test"}"#.utf8)
    let signer = "0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A"
    let sig = "1363ddb134426f019b352373cf5ef07d65ba6e638461ff6296d2ed413b107aa60654948a61656f9583cabaa1caf6eedbea8769e7eed4673040b1ab94c75bdc811b"

    func testExpectedTextIsModelAndHashes() {
        XCTAssertEqual(ResponseSignature.expectedText(request: req, response: resp, model: "Qwen/Qwen3.8-27B"),
                       "Qwen/Qwen3.8-27B:0bd03bb47ec6a87eee365e7245869fecf5b06aaa90265683eb0ee3aab289d7a0:d9db2704bb96abc899103382df597b326ad20948c3f14afc9ea0948e96adb537")
    }

    func testEIP191Recovery() {
        XCTAssertEqual(ResponseSignature.recoverEIP191(message: Data(ResponseSignature.expectedText(request: req, response: resp, model: "Qwen/Qwen3.8-27B").utf8), signature: sig)?.lowercased(),
                       signer.lowercased())
    }

    func testSignatureVerifies() {
        let text = ResponseSignature.expectedText(request: req, response: resp, model: "Qwen/Qwen3.8-27B")
        let s = ResponseSignature(text: text, signature: sig, signingAddress: signer, signingAlgo: "ecdsa", kind: "provider_tee")
        XCTAssertEqual(s.verify(expectedText: text, expectedSigner: signer, expectedAlgo: "ecdsa"), .verified)
        // Other bytes: the hashes differ.
        let other = ResponseSignature.expectedText(request: req, response: Data(resp + Data(" ".utf8)), model: "Qwen/Qwen3.8-27B")
        XCTAssertEqual(s.verify(expectedText: other, expectedSigner: signer, expectedAlgo: "ecdsa"), .textMismatch)
        // A signer that isn't the attested key.
        if case .signerMismatch = s.verify(expectedText: text, expectedSigner: "0x835ab53d20294ef795906dff21ae4c045336aa26", expectedAlgo: "ecdsa") {} else { XCTFail() }
        // A forged signature.
        var bad = Data(hexString: sig)!; bad[10] ^= 1
        let forged = ResponseSignature(text: text, signature: bad.hex, signingAddress: signer, signingAlgo: "ecdsa", kind: "provider_tee")
        XCTAssertNotEqual(forged.verify(expectedText: text, expectedSigner: signer, expectedAlgo: "ecdsa"), .verified)
    }

    func testUnavailableSignatureIsNotASignature() {
        XCTAssertNil(ResponseSignature(json: Data(#"{"error_code":"stream_disconnected","message":"unavailable"}"#.utf8)))
    }

    // MARK: Models, tools, proof

    func testModelDiscoveryPicksNearTEEModels() throws {
        let models = NearAICloud.teeModels(try fixture("models", "json"))
        XCTAssertEqual(models.first?.id, NearAICloud.defaultModel)
        XCTAssertTrue(models.contains { $0.id == "z-ai/glm-5.3-flash" })
        XCTAssertFalse(models.contains { $0.id.hasPrefix("anthropic/") || $0.id.hasPrefix("openai/") }, "third-party models aren't NEAR TEE models")
        XCTAssertFalse(models.contains { $0.id.contains("abliterated") })
    }

    /// Private Cloud sends all 30 tools of the v3 registry (hermit-lab/train/spec/hermit_tools_v3.json): the same names in
    /// the same order as the on-device v3 lines, and the lab's file byte for byte.
    func testToolSchemaIsHermits() throws {
        XCTAssertEqual(CloudTools.names.count, 30)
        XCTAssertEqual(CloudTools.names, ToolPacks.allNames)
        XCTAssertEqual(CloudTools.schemaData, try fixture("hermit_tools_v3", "json"))
        // Every tool today's on-device model has is still there, so nothing it can do is lost in Private Cloud.
        XCTAssertTrue(Set(HermitPrompt.names(HermitPrompt.toolLines)).isSubset(of: Set(CloudTools.names)))
        // Money tools and card tools are all in the list, and every one of them is known to the guard.
        for name in CloudTools.names where name.hasPrefix("prepare_") { XCTAssertTrue(ToolGuard.moneyTools.contains(name), name) }
        XCTAssertTrue(ToolGuard.moneyTools.union(ToolGuard.cardTools).isSubset(of: Set(CloudTools.names)))
    }

    /// The system prompt is the v3 cloud prompt as shipped, then where this session runs, then the name and the notes.
    func testCloudPromptIsV3() {
        let p = NearCloudAgent.systemPrompt(name: "Maya", memory: ["Keep answers very short."])
        XCTAssertTrue(p.hasPrefix("You are Hermit, the assistant inside a self-custody crypto wallet app"), String(p.prefix(80)))
        XCTAssertGreaterThan(NearCloudAgent.baseSystemPrompt.count, 40_000, "the bundled prompt was read")
        // It explains every tool it is given.
        for tool in CloudTools.names { XCTAssertTrue(p.contains("**\(tool)**"), tool) }
        XCTAssertTrue(p.contains("Never claim money moved."))
        XCTAssertTrue(p.contains("This session is Hermit's Private Cloud"))
        XCTAssertTrue(p.hasSuffix("The user wants to be called Maya.\nThe user's standing notes (hermit.md). Follow them:\n- Keep answers very short."))
        // On a Mac the same text reads Touch ID throughout.
        XCTAssertEqual(NearCloudAgent.deviceText("with Face ID (Touch ID on a Mac), or Face ID.", bio: "Touch ID"), "with Touch ID, or Touch ID.")
        XCTAssertEqual(NearCloudAgent.deviceText("with Face ID (Touch ID on a Mac).", bio: "Face ID"), "with Face ID (Touch ID on a Mac).")
    }

    func testProofHeadline() throws {
        let (bundle, nonce, _) = try report("qwen-report")
        let pre = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, at: recorded)
        var good = NearCloudAgent.SignedCheck(); good.available = true; good.kind = "provider_tee"; good.textMatches = true; good.signerMatches = true
        XCTAssertEqual(NearCloudAgent.proof(pre, [good, good]).headline, "Verified in a TEE")
        XCTAssertEqual(NearCloudAgent.proof(pre, [good, NearCloudAgent.SignedCheck()]).headline, "Not verified")
        XCTAssertEqual(pre.proof(completions: 0, signed: 0, kind: nil, replyChecks: []).headline, "Enclave verified")
        var gw = good; gw.kind = "gateway"
        XCTAssertFalse(NearCloudAgent.proof(pre, [gw]).fullyVerified)
        // What the phone can't check is always listed as not checked, never as passed.
        let p = NearCloudAgent.proof(pre, [good])
        XCTAssertTrue(p.checks.filter { $0.id.hasPrefix("nc.") }.allSatisfy { $0.status == .skipped && $0.source == .none })
    }

    func testCleanDropsThinking() {
        XCTAssertEqual(NearCloudAgent.clean("<think>plan</think>\n\nHi · there"), "Hi, there")
        XCTAssertEqual(NearCloudAgent.clean("reasoning</think>Answer"), "Answer")
    }

    func testCompletionReadsFinishReason() throws {
        let raw = Data(#"{"id":"chatcmpl-1","choices":[{"index":0,"finish_reason":"length","message":{"role":"assistant","content":"The first half of"}}]}"#.utf8)
        let c = try XCTUnwrap(NearCloudAgent.completion(raw))
        XCTAssertEqual(c.id, "chatcmpl-1")
        XCTAssertEqual(c.finish, "length")
        XCTAssertEqual(c.message["content"] as? String, "The first half of")
        XCTAssertNil(NearCloudAgent.completion(Data(#"{"choices":[]}"#.utf8)))
    }

    func testRequestBodyTurnsQwenReasoningOff() async throws {
        let state = CloudState()
        let qwenBody = try await state.body(model: "Qwen/Qwen3.8-27B", tools: nil)
        let qwen = try XCTUnwrap(JSONSerialization.jsonObject(with: qwenBody) as? [String: Any])
        XCTAssertEqual(qwen["max_tokens"] as? Int, 4096)
        XCTAssertEqual((qwen["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        let glmBody = try await state.body(model: "z-ai/glm-5.3-flash", tools: nil)
        let glm = try XCTUnwrap(JSONSerialization.jsonObject(with: glmBody) as? [String: Any])
        XCTAssertNil(glm["chat_template_kwargs"], "other families use other switches")
    }

    func testMissingGPUVerdictBlocksSending() throws {
        let (bundle, nonce, _) = try report("qwen-report")
        let missing = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, nvidia: [0: (nil, "NVIDIA NRAS unreachable")], at: recorded)
        XCTAssertEqual(missing.checks.first { $0.id == "model0.nras" }?.status, .skipped, "shown honestly as not checked")
        XCTAssertTrue(missing.passed)
        XCTAssertFalse(missing.gpuVerdicts, "but chat must not send")
        let good = Preflight.evaluate(model: "Qwen/Qwen3.8-27B", nonce: nonce, bundle: bundle, nvidia: [0: (true, "ok")], at: recorded)
        XCTAssertTrue(good.passed && good.gpuVerdicts)
    }

    // NRAS tokens: signed here with a throwaway P-384 key published in a test key set.
    func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func nrasToken(_ key: P384.Signing.PrivateKey, kid: String = "test-kid", claims: [String: Any]) throws -> String {
        let header = b64url(try JSONSerialization.data(withJSONObject: ["alg": "ES384", "kid": kid, "typ": "JWT"]))
        let body = b64url(try JSONSerialization.data(withJSONObject: claims))
        let sig = try key.signature(for: Data((header + "." + body).utf8))
        return header + "." + body + "." + b64url(sig.rawRepresentation)
    }
    func nrasKeys(_ key: P384.Signing.PrivateKey) throws -> Data {
        let raw = key.publicKey.rawRepresentation
        return try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "crv": "P-384", "kid": "test-kid",
                                                                    "x": b64url(raw.prefix(48)), "y": b64url(raw.suffix(48))]]])
    }

    func testNRASTokenIsCheckedBeforeItsVerdict() throws {
        let key = P384.Signing.PrivateKey()
        let keys = try nrasKeys(key)
        let nonce = AttestationVerifier.newNonce()
        let now = Date()
        let claims: [String: Any] = ["iss": "https://nras.attestation.nvidia.com", "x-nvidia-overall-att-result": true, "eat_nonce": nonce,
                                     "nbf": Int(now.timeIntervalSince1970) - 10, "iat": Int(now.timeIntervalSince1970) - 10,
                                     "exp": Int(now.timeIntervalSince1970) + 3600]
        let good = try nrasToken(key, claims: claims)
        XCTAssertTrue(NearAICloud.nrasVerdict(token: good, keys: keys, nonce: nonce, at: now).ok)
        XCTAssertTrue(NearAICloud.nrasVerdict(token: good, keys: keys, nonce: nonce.uppercased(), at: now).ok, "hex compares case-insensitively")
        // A token for another request's evidence can't be replayed.
        XCTAssertFalse(NearAICloud.nrasVerdict(token: good, keys: keys, nonce: AttestationVerifier.newNonce(), at: now).ok)
        // Signed by a key that isn't in NVIDIA's set.
        XCTAssertFalse(NearAICloud.nrasVerdict(token: try nrasToken(P384.Signing.PrivateKey(), claims: claims), keys: keys, nonce: nonce, at: now).ok)
        XCTAssertFalse(NearAICloud.nrasVerdict(token: try nrasToken(key, kid: "other", claims: claims), keys: keys, nonce: nonce, at: now).ok)
        // An edited payload no longer matches the signature.
        var parts = good.split(separator: ".").map(String.init)
        var edited = claims; edited["eat_nonce"] = AttestationVerifier.newNonce()
        parts[1] = b64url(try JSONSerialization.data(withJSONObject: edited))
        XCTAssertFalse(NearAICloud.nrasVerdict(token: parts.joined(separator: "."), keys: keys, nonce: edited["eat_nonce"] as! String, at: now).ok)
        // Expired, from another issuer, or a false verdict.
        XCTAssertFalse(NearAICloud.nrasVerdict(token: good, keys: keys, nonce: nonce, at: now.addingTimeInterval(7200)).ok)
        var other = claims; other["iss"] = "https://example.com"
        XCTAssertFalse(NearAICloud.nrasVerdict(token: try nrasToken(key, claims: other), keys: keys, nonce: nonce, at: now).ok)
        var no = claims; no["x-nvidia-overall-att-result"] = false
        XCTAssertFalse(NearAICloud.nrasVerdict(token: try nrasToken(key, claims: no), keys: keys, nonce: nonce, at: now).ok)
    }

    /// Live: fetch a fresh report and check it. Skipped unless HERMIT_LIVE=1 (needs network).
    func testLiveAttestation() async throws {
        guard ProcessInfo.processInfo.environment["HERMIT_LIVE"] == "1" else { throw XCTSkip("set HERMIT_LIVE=1") }
        let pre = try await Preflight.run(model: NearAICloud.defaultModel)
        XCTAssertTrue(pre.passed, "\(pre.checks.filter { $0.status == .fail })")
        XCTAssertEqual(pre.checks.first { $0.id == "gw.tls" }?.status, .pass, "peer key read on the same connection")
        XCTAssertEqual(pre.checks.first { $0.id == "model0.nras" }?.status, .pass)
        pre.connection?.invalidate()
    }
}
