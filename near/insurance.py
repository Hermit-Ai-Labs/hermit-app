#!/usr/bin/env python3
"""Hermit AI insurance (hermit-insurance.near): read the pool and claims, and the AI reviewer's tools.

    .venv/bin/python near/insurance.py info                 # pool, paid in and out, members, claims
    .venv/bin/python near/insurance.py claims               # newest first, with the AI verdict and the decision
    .venv/bin/python near/insurance.py check 3              # one claim: is its fingerprint really on hermit-blackbox.near,
                                                            # written by the claimant? does the evidence hash to it?
    .venv/bin/python near/insurance.py --key-file K --yes review 3 approve "The review showed 200; they asked for 20."

Only the owner can approve or pay (in the Hermit app, Settings > Safety > AI insurance > Claims). The reviewer key can
only write a verdict. No key is needed to read.
"""
import argparse, hashlib, json, sys
from pathlib import Path

import requests

CONTRACT = {"mainnet": "hermit-insurance.near", "testnet": None}
BLACKBOX = {"mainnet": "hermit-blackbox.near", "testnet": None}
NEARBLOCKS = {"mainnet": "https://api.nearblocks.io", "testnet": "https://api-testnet.nearblocks.io"}
USDC = 1_000_000


def usd(x):
    return f"${int(x) / USDC:,.2f}"


def find_record(network, blackbox, fp):
    """The Black Box record with this fingerprint, from the contract's event logs (via NearBlocks). None if not found."""
    url = f"{NEARBLOCKS[network]}/v1/account/{blackbox}/receipts"
    try:
        r = requests.get(url, params={"per_page": 25, "order": "desc", "method": "record"}, timeout=20)
        r.raise_for_status()
    except requests.RequestException as e:
        return {"error": str(e)}
    for rc in r.json().get("txns", []):
        tx = rc.get("transaction_hash")
        try:
            d = requests.get(f"{NEARBLOCKS[network]}/v1/txns/{tx}/receipts", timeout=20).json()
        except requests.RequestException:
            continue
        text = json.dumps(d)
        if fp in text:
            return {"tx": tx, "by": rc.get("predecessor_account_id")}
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    ap.add_argument("--contract")
    ap.add_argument("--blackbox")
    ap.add_argument("--key-file")
    ap.add_argument("--account")
    ap.add_argument("--yes", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    c = sub.add_parser("claims"); c.add_argument("--limit", type=int, default=20)
    k = sub.add_parser("check"); k.add_argument("id", type=int)
    r = sub.add_parser("review"); r.add_argument("id", type=int); r.add_argument("verdict", choices=["approve", "reject", "unsure"]); r.add_argument("reason")
    a = ap.parse_args()

    sys.path.insert(0, str(Path(__file__).parent))
    import guard
    chain = guard.Chain(a.network)
    chain.yes = a.yes or a.network == "testnet"
    cid = a.contract or CONTRACT[a.network]
    bb = a.blackbox or BLACKBOX[a.network]
    if not cid:
        raise SystemExit("pass --contract on testnet")
    view = lambda m, args=None: chain.view(cid, m, args or {})

    if a.cmd == "info":
        i = view("info")
        print(f"{cid}  pool {usd(i['pool'])}  in {usd(i['paid_in'])}  out {usd(i['paid_out'])}  owed {usd(i['owed'])}  "
              f"members {i['members']}  claims {i['claims']}  price {usd(i['price'])} / {i['period_days']} days")
        print(f"owner {i['owner']}  reviewer {i['reviewer']}  token {i['token']}")
        return 0
    if a.cmd == "claims":
        for c in view("claims", {"limit": a.limit}):
            print(f"#{c['id']:<4} {c['status']:<9} loss {usd(c['loss']):>10}  award {usd(c['award']):>10}  paid {usd(c['paid']):>10}  "
                  f"AI {c.get('ai_verdict') or '-':<8} {c['by'][:20]}")
        return 0
    if a.cmd == "check":
        c = view("get_claim", {"id": a.id})
        if not c:
            raise SystemExit("no such claim")
        ok_hash = hashlib.sha256(c["evidence"].encode()).hexdigest() == c["fp"]
        print(f"[{'PASS' if ok_hash else 'FAIL'}] evidence hashes to the fingerprint {c['fp'][:16]}…")
        rec = find_record(a.network, bb, c["fp"]) if bb else None
        if rec and "tx" in rec:
            same = rec.get("by") == c["by"]
            print(f"[{'PASS' if same else 'FAIL'}] recorded on {bb} in {rec['tx']} by {rec.get('by')}")
        else:
            print(f"[----] couldn't find the record on {bb} automatically{': ' + rec['error'] if rec and 'error' in rec else ''}; check by hand")
        print("\nevidence:\n" + json.dumps(json.loads(c["evidence"]), indent=2) if c["evidence"].startswith("{") else c["evidence"])
        print(f"\nclaimed loss {usd(c['loss'])}; note: {c['note']}")
        return 0 if ok_hash else 1
    if a.cmd == "review":
        key = guard.load_key(a)
        acct = guard.signer_for(a, key)
        body = json.dumps({"id": a.id, "verdict": a.verdict, "reason": a.reason}).encode()
        h, res = chain.send(key, acct, cid, [guard.act_call("ai_review", body, 30 * guard.TGAS, 0)])
        return guard.report(chain, h, res)


if __name__ == "__main__":
    sys.exit(main())
