#!/usr/bin/env python3
"""Hermit Black Box (hermit-blackbox.near): the model registry and the flight recorder.

    python3 near/blackbox.py digests                      # pin digest of every model the app ships (no network)
    .venv/bin/python near/blackbox.py info                # the live contract: owner, models, records
    .venv/bin/python near/blackbox.py models              # every published model
    .venv/bin/python near/blackbox.py check               # does each model the app pins match the chain?
    .venv/bin/python near/blackbox.py --key-file K publish   # owner: publish every model not yet on chain
    .venv/bin/python near/blackbox.py --key-file K record --fp <64 hex> --kind swap   # write one fingerprint

The pin digest is SHA-256 over one line per pinned file, sorted by path: "path<TAB>size<TAB>sha256<LF>". The app computes
the same digest from Packages/HermitKit/Sources/HermitModel/ModelPins.swift (BlackBox.pinDigest).
`info`, `models` and `check` need no key. Reuses near/guard.py for keys, RPC and signing.
"""
import argparse, hashlib, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINS = ROOT / "Packages/HermitKit/Sources/HermitModel/ModelPins.swift"
CATALOG = ROOT / "Packages/HermitKit/Sources/HermitModel/ModelCatalog.swift"
CONTRACT = {"mainnet": "hermit-blackbox.near", "testnet": None}

# Held-out test results, from docs/MODEL-RESULTS.md.
SCORES = {
    "aiquantgod/Hermit-1.3-4B-MLX-5bit": "1,801 held-out tests, 30 tools: never claims a move without a tool result 1801/1801; "
        "never asks for a key 60/60; no money call from injected text 59/60; clean tool calls 98.3%.",
    "aiquantgod/Hermit-1.3-Lite-MLX-6bit": "1,843 held-out tests, 30 tools: never claims a move without a tool result 1835/1843; "
        "never asks for a key 60/60; no money call from injected text 60/60; clean tool calls 98.3%.",
    "rahulol/Hermit-1.2-4B-MLX-4bit": "160 held-out tests, 12 tools: whole task right 87% (base Qwen3-4B 57%); right first tool "
        "100%; prepares a swap when asked 8/8; says prepared without doing it 0 times.",
    "rahulol/Hermit-1.1-Lite-MLX-4bit": "Earlier release, kept for people who still have it. Superseded by Hermit 1.3 Lite.",
}


def pins():
    """{id: {"revision", "files": [(path, size, sha256)]}} parsed from ModelPins.swift."""
    src = PINS.read_text()
    out = {}
    for m in re.finditer(r'"([^"]+)":\s*ModelPin\(revision: "([0-9a-f]{40})".*?\n        \]\),', src, re.S):
        files = re.findall(r'\.init\(path: "([^"]+)", size: (\d+), sha256: "([0-9a-f]{64})"', m.group(0))
        out[m.group(1)] = {"revision": m.group(2), "files": [(p, int(s), h) for p, s, h in files]}
    return out


def names():
    return dict(re.findall(r'ModelSpec\(id: "([^"<]+)", revision: "[0-9a-f]{40}", name: "([^"]+)"', CATALOG.read_text()))


def pin_digest(files):
    lines = "".join(f"{p}\t{s}\t{h}\n" for p, s, h in sorted(files))
    return hashlib.sha256(lines.encode()).hexdigest()


def entry(mid, pin, nm):
    weights = next(f for f in pin["files"] if f[0] == "model.safetensors")
    return {"id": mid, "name": nm.get(mid, mid.split("/")[-1]), "revision": pin["revision"], "weights_sha256": weights[2],
            "pin_digest": pin_digest(pin["files"]), "bytes": str(weights[1]), "scores": SCORES.get(mid, "See the model card."),
            "url": f"https://huggingface.co/{mid}"}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    ap.add_argument("--contract", help="contract account (default hermit-blackbox.near on mainnet)")
    ap.add_argument("--key-file")
    ap.add_argument("--yes", action="store_true", help="really send on mainnet (without it, mainnet calls are only shown)")
    ap.add_argument("--account", help="signer account, if the key file has none")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("digests"); sub.add_parser("info"); sub.add_parser("models"); sub.add_parser("check")
    sub.add_parser("publish")
    r = sub.add_parser("record"); r.add_argument("--fp", required=True); r.add_argument("--kind", required=True); r.add_argument("--model")
    a = ap.parse_args()

    nm, ps = names(), pins()
    if a.cmd == "digests":
        for mid, p in ps.items():
            e = entry(mid, p, nm)
            print(f"{e['name']:<16} {mid}\n  weights {e['weights_sha256']}\n  pin     {e['pin_digest']}")
        return 0

    sys.path.insert(0, str(Path(__file__).parent))
    import guard  # keys, RPC, signing
    chain = guard.Chain(a.network)
    chain.yes = a.yes or a.network == "testnet"
    cid = a.contract or CONTRACT[a.network]
    if not cid:
        raise SystemExit("pass --contract on testnet")

    def view(m, args=None):
        return chain.view(cid, m, args or {})

    if a.cmd == "info":
        print(json.dumps(view("info"), indent=2)); return 0
    if a.cmd == "models":
        print(json.dumps(view("models", {"limit": 100}), indent=2)); return 0
    if a.cmd == "check":
        bad = 0
        for mid, p in ps.items():
            e = entry(mid, p, nm)
            ok = view("check_model", {"id": mid, "weights_sha256": e["weights_sha256"], "pin_digest": e["pin_digest"]})
            print(f"[{'PASS' if ok else 'FAIL'}] {e['name']} ({mid}) matches {cid}")
            bad += not ok
        return 1 if bad else 0

    key = guard.load_key(a)
    acct = guard.signer_for(a, key)
    if a.cmd == "publish":
        rc = 0
        for mid, p in ps.items():
            if view("get_model", {"id": mid}):
                print("already on chain:", mid); continue
            body = json.dumps({"model": entry(mid, p, nm)}).encode()
            h, res = chain.send(key, acct, cid, [guard.act_call("publish_model", body, 30 * guard.TGAS, 1)])
            rc |= guard.report(chain, h, res)
        return rc
    if a.cmd == "record":
        args = {"fp": a.fp, "kind": a.kind, **({"model": a.model} if a.model else {})}
        h, res = chain.send(key, acct, cid, [guard.act_call("record", json.dumps(args).encode(), 3 * guard.TGAS, 0)])
        return guard.report(chain, h, res)


if __name__ == "__main__":
    sys.exit(main())
