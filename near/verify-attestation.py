#!/usr/bin/env python3
"""Verify NEAR AI Cloud TEE attestation the way Hermit's Private Cloud mode does, step by step.

No API key needed for attestation. With NEARAI_API_KEY set, it also sends one tiny completion and checks the
response signature against the attested model signer.

    python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
    .venv/bin/python near/verify-attestation.py                       # live, default model
    .venv/bin/python near/verify-attestation.py --model z-ai/glm-5.3-flash
    .venv/bin/python near/verify-attestation.py --report Packages/HermitKit/Tests/HermitCloudTests/Fixtures/qwen-report.json \
        --nonce "$(cat Packages/HermitKit/Tests/HermitCloudTests/Fixtures/qwen-report.nonce)" --offline
    .venv/bin/python near/verify-attestation.py --sdk                 # also cross-check with NEAR's official SDK

Checks follow https://docs.near.ai/cloud/verification (gateway attestation, model attestations,
quote/nonce/signer reference, response signatures). Exit code 1 if any required check fails.
Nothing is stored: the report is only written to disk when you pass --save.
"""
import argparse, asyncio, base64, hashlib, http.client, json, os, secrets, ssl, struct, sys, time, urllib.parse

import requests

API = "https://cloud-api.near.ai/v1"
NRAS = "https://nras.attestation.nvidia.com/v3/attest/gpu"
DEFAULT_MODEL = "Qwen/Qwen3.8-27B"
ACCEPTED_TCB = {"UpToDate"}

results = []  # (scope, check, ok, detail)


def check(scope, name, ok, detail=""):
    results.append((scope, name, ok, detail))
    mark = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print(f"  [{mark}] {name}" + (f"  ({detail})" if detail else ""))
    return ok


def _json(v):
    return json.loads(v) if isinstance(v, str) else v


# --- Intel TDX quote v4, read straight from the bytes (the same parser Hermit uses in Swift) ---------------
def parse_td_quote(raw: bytes) -> dict:
    version, = struct.unpack_from("<H", raw, 0)
    tee_type, = struct.unpack_from("<I", raw, 4)
    body = raw[48:48 + 584]
    return {
        "version": version, "tee_type": tee_type,
        "td_attributes": body[120:128], "mr_td": body[136:184], "mr_config_id": body[184:232],
        "rt_mr": [body[328 + 48 * i: 376 + 48 * i] for i in range(4)], "report_data": body[520:584],
    }


def replay_rtmr3(event_log) -> bytes:
    rtmr3 = bytes(48)
    for e in _json(event_log):
        if e.get("imr") != 3:
            continue
        d = hashlib.sha384(struct.pack("<I", e["event_type"]) + b":" + e["event"].encode() + b":"
                           + bytes.fromhex(e.get("event_payload") or "")).digest()
        if e.get("digest") and bytes.fromhex(e["digest"]) != d:
            raise ValueError(f"digest mismatch for event {e['event']}")
        rtmr3 = hashlib.sha384(rtmr3 + d).digest()
    return rtmr3


async def verify_report(scope, report, nonce, offline):
    print(f"\n{scope}: signer {report.get('signing_address')} ({report.get('signing_algo')})")
    raw = bytes.fromhex(report["intel_quote"])
    q = parse_td_quote(raw)
    check(scope, "Quote is Intel TDX v4", q["version"] == 4 and q["tee_type"] == 0x81, f"version {q['version']}, tee 0x{q['tee_type']:x}")

    # 1. Quote signature chain and TCB status (Intel DCAP via dcap-qvl, collateral from PCCS).
    if offline:
        check(scope, "Intel DCAP quote verification (dcap-qvl)", None, "skipped with --offline")
    else:
        import dcap_qvl
        try:
            v = await dcap_qvl.get_collateral_and_verify(raw)
            body = json.loads(v.to_json())["report"]["TD10"]
            ok = v.status in ACCEPTED_TCB
            check(scope, "Intel DCAP quote verification (dcap-qvl)", ok, f"TCB {v.status}" + (f", advisories {v.advisory_ids}" if v.advisory_ids else ""))
            same = bytes.fromhex(body["report_data"]) == q["report_data"] and bytes.fromhex(body["rt_mr3"]) == q["rt_mr"][3]
            check(scope, "Local quote parser matches dcap-qvl", same)
        except Exception as e:  # noqa: BLE001
            check(scope, "Intel DCAP quote verification (dcap-qvl)", False, str(e))

    check(scope, "TDX debug mode off", q["td_attributes"][0] & 1 == 0, f"td_attributes {q['td_attributes'].hex()}")

    # 2. Nonce and signer bound in the quote's report data: signer (zero-padded to 32) || client nonce.
    check(scope, "Echoed nonce matches ours", (report.get("request_nonce") or "").lower() == nonce.lower())
    check(scope, "Quote report data ends with our nonce", q["report_data"][32:] == bytes.fromhex(nonce))
    ident = bytes.fromhex(report["signing_address"].removeprefix("0x"))
    want = {"ecdsa": 20, "ed25519": 32}.get(report["signing_algo"])
    fp = report.get("tls_cert_fingerprint")
    bound = hashlib.sha256(ident + bytes.fromhex(fp)).digest() if fp else ident.ljust(32, b"\0")
    check(scope, "Quote report data binds the signing address", want == len(ident) and q["report_data"][:32] == bound)
    if report.get("report_data"):
        check(scope, "HTTP report_data equals quote report data", bytes.fromhex(report["report_data"]) == q["report_data"])

    # 3. Measured configuration: MRCONFIGID = 01 || sha256(app_compose) || 15 zero bytes.
    app_compose = _json(report["info"]["tcb_info"])["app_compose"]
    ch = hashlib.sha256(app_compose.encode()).digest()
    check(scope, "MRCONFIGID matches app_compose", q["mr_config_id"] == b"\x01" + ch + bytes(15), f"compose sha256 {ch.hex()[:16]}…")

    # 4. Runtime event log replays to RTMR3.
    try:
        check(scope, "Event log replays to RTMR3", replay_rtmr3(report["event_log"]) == q["rt_mr"][3])
    except ValueError as e:
        check(scope, "Event log replays to RTMR3", False, str(e))

    # 5. GPU evidence (model reports): nonce inside the NVIDIA payload, then NVIDIA NRAS verdict.
    if report.get("nvidia_payload"):
        gpu = _json(report["nvidia_payload"])
        check(scope, "GPU evidence carries our nonce", str(gpu.get("nonce", "")).lower() == nonce.lower(),
              f"{len(gpu.get('evidence_list', []))} GPUs, arch {gpu.get('arch')}")
        if offline:
            check(scope, "NVIDIA NRAS GPU verdict", None, "skipped with --offline")
        else:
            try:
                r = requests.post(NRAS, json=gpu, timeout=60, headers={"Accept": "application/json"})
                r.raise_for_status()
                token = r.json()[0][1]
                payload = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
                check(scope, "NVIDIA NRAS GPU verdict", payload.get("x-nvidia-overall-att-result") is True,
                      f"eat_nonce {str(payload.get('eat_nonce', ''))[:12]}…")
            except Exception as e:  # noqa: BLE001
                check(scope, "NVIDIA NRAS GPU verdict", False, str(e))


class Gateway:
    """One TLS connection to cloud-api.near.ai, kept open so the report and the completion share it."""
    def __init__(self):
        self.c = http.client.HTTPSConnection("cloud-api.near.ai", context=ssl.create_default_context(), timeout=120)
        self.c.connect()
        self.sock = self.c.sock

    def peer_spki_sha256(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        cert = x509.load_der_x509_certificate(self.c.sock.getpeercert(binary_form=True))
        return hashlib.sha256(cert.public_key().public_bytes(serialization.Encoding.DER,
                                                            serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()

    def same_connection(self):
        return self.c.sock is self.sock

    def request(self, method, path, body=None, headers=None):
        self.c.request(method, path, body=body, headers=headers or {})
        r = self.c.getresponse()
        data = r.read()
        if r.status >= 300:
            raise RuntimeError(f"{method} {path}: HTTP {r.status} {data[:200]!r}")
        return data


def verify_completion(gw, model, model_signers, gateway_signer, key):
    """One non-streamed completion; the model enclave signs <model>:<sha256(request)>:<sha256(response)>."""
    from eth_account import Account
    from eth_account.messages import encode_defunct
    print("\nCompletion")
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": "Reply with the word ok."}],
                       "stream": False, "max_tokens": 16}, separators=(",", ":")).encode()
    raw = gw.request("POST", "/v1/chat/completions", body=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "x-no-aliasing": "true",
        "Accept-Encoding": "identity", "Accept": "application/json"})
    check("completion", "Prompt sent on the attested TLS connection", gw.same_connection())
    chat_id = json.loads(raw)["id"]
    req_h, resp_h = hashlib.sha256(body).hexdigest(), hashlib.sha256(raw).hexdigest()
    sig = None
    for _ in range(5):
        s = requests.get(f"{API}/signature/{chat_id}", params={"signing_algo": "ecdsa"}, timeout=30,
                         headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
        if s.status_code == 200 and "signature" in s.json():
            sig = s.json(); break
        time.sleep(1)
    if not check("completion", "Signature available", sig is not None, chat_id):
        return
    kind = sig.get("signature_kind")
    expected = f"{model}:{req_h}:{resp_h}" if kind == "provider_tee" else f"{req_h}:{resp_h}"
    check("completion", "Signed text covers our exact request and response bytes", sig["text"] == expected, f"kind {kind}")
    rec = Account.recover_message(encode_defunct(text=sig["text"]), signature=sig["signature"])
    signers = model_signers if kind == "provider_tee" else [gateway_signer]
    match = [a for a in signers if a and a.lower() == rec.lower()]
    check("completion", "Signer is the attested " + ("model enclave" if kind == "provider_tee" else "gateway"), len(match) == 1, rec)


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--report", help="verify a saved report instead of fetching one (needs --nonce)")
    ap.add_argument("--nonce", help="the nonce the saved report was fetched with")
    ap.add_argument("--save", help="write the fetched report to this file")
    ap.add_argument("--offline", action="store_true", help="skip the network verifiers (Intel collateral, NVIDIA NRAS)")
    ap.add_argument("--sdk", action="store_true", help="also run NEAR's official SDK verify(model)")
    a = ap.parse_args()

    gw = None
    if a.report:
        if not a.nonce:
            sys.exit("--report needs --nonce")
        nonce, report = a.nonce, json.load(open(a.report))
        print(f"Saved report {a.report}, nonce {nonce}")
    else:
        nonce = secrets.token_hex(32)  # fresh 32 random bytes, generated here
        print(f"Model {a.model}\nNonce {nonce} (fresh, from this machine)")
        gw = Gateway()  # no API key is sent on this connection before the report is verified
        q = urllib.parse.urlencode({"model": a.model, "provider": "near", "signing_algo": "ecdsa", "nonce": nonce,
                                    "include_tls_fingerprint": "true"})
        raw = gw.request("GET", f"/v1/attestation/report?{q}", headers={"Accept": "application/json", "x-no-aliasing": "true"})
        report = json.loads(raw)
        if a.save:
            open(a.save, "wb").write(raw)

    await verify_report("Gateway", report["gateway_attestation"], nonce, a.offline)
    if gw:
        fp = (report["gateway_attestation"].get("tls_cert_fingerprint") or "").lower()
        peer = gw.peer_spki_sha256()
        check("Gateway", "This TLS connection ends at the key the gateway quote binds", fp == peer, f"peer SPKI sha256 {peer[:16]}…")
    models = report.get("model_attestations") or []
    check("Model", "Model evidence returned", bool(models), f"{len(models)} candidate(s)")
    for i, m in enumerate(models):
        await verify_report(f"Model {m.get('model_name', a.model)} #{i + 1}", m, nonce, a.offline)

    key = os.environ.get("NEARAI_API_KEY")
    if key and gw:
        verify_completion(gw, a.model, [m["signing_address"] for m in models], report["gateway_attestation"]["signing_address"], key)
    else:
        print("\nCompletion")
        check("completion", "Response signature", None, "set NEARAI_API_KEY to send one completion and verify its signature")

    if a.sdk and not a.offline:
        print("\nNEAR official SDK (nearai-inference-sdk) verify(model)")
        try:
            from nearai_inference_sdk import InferenceClient
            async with InferenceClient(key) as c:
                v = await c.verify(a.model)
            check("sdk", "SDK gateway verification", True, f"TCB {v.gateway.tcb_status}")
            check("sdk", "SDK model verification", len(v.models) > 0, f"{len(v.models)} verified model report(s)")
        except Exception as e:  # noqa: BLE001
            check("sdk", "SDK verify(model)", False, str(e))

    failed = [r for r in results if r[2] is False]
    print(f"\n{sum(1 for r in results if r[2])} passed, {len(failed)} failed, {sum(1 for r in results if r[2] is None)} skipped")
    print("Not checked here: image provenance of the container digests, and the gateway-to-model hop (see near/README.md).")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
