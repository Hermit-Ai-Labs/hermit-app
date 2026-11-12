#!/usr/bin/env python3
"""Hermit Guard keeper: runs the standing orders that are due. Safe to run every minute from cron.

    */1 * * * *  GUARD_KEY_FILE=/path/keeper.json /path/.venv/bin/python /path/contracts/guard/keeper.py >> keeper.log 2>&1

What it does, in order:
  1. asks the contract for due orders (view call due_orders, 20 owners per page, all pages);
  2. for each one, calls execute_order. The contract itself decides whether the order may run, so a second keeper,
     a manual run or a retry can never pay twice: the late caller is refused ("order not due yet" / "no such order").
  3. logs one line per action:  <utc time> <action> <owner> #<order> <detail>   (action: paid | skipped | failed | error)
The key only pays gas; it has no power over any vault. Use a separate account with a few NEAR on it.
Takes a lock file so overlapping cron runs do nothing. Exit 0 when the pass finished, 1 on an RPC error.
Uses near/guard.py (same repo) for the RPC and transaction code.
"""
import argparse, fcntl, importlib.util, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guard_cli", os.environ.get("GUARD_PY") or HERE.parents[1] / "near" / "guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def log(action, owner="-", order="-", detail=""):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {action} {owner} #{order} {detail}".rstrip(), flush=True)


def due_orders(chain, contract):
    total = int(chain.view(contract, "owners_count"))
    out, i = [], 0
    while i < total:
        out += chain.view(contract, "due_orders", {"from_index": i, "limit": 20})
        i += 20
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--network", choices=["testnet", "mainnet"], default="testnet")
    ap.add_argument("--rpc")
    ap.add_argument("--contract")
    ap.add_argument("--key-file", help="keeper key (or env GUARD_KEY_FILE / GUARD_KEY)")
    ap.add_argument("--account", help="keeper account (default: account_id in the key file)")
    ap.add_argument("--max", type=int, default=50, help="most orders to run in one pass (default 50)")
    ap.add_argument("--dry-run", action="store_true", help="only list what would run")
    ap.add_argument("--lock", default="/tmp/hermit-guard-keeper.lock")
    a = ap.parse_args()
    contract = a.contract or guard.DEFAULT_CONTRACT.get(a.network)
    if not contract:
        sys.exit(f"--contract is required on {a.network}")
    lock = open(a.lock, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("skipped", detail="another keeper run is still going")
        return 0
    chain = guard.Chain(a.network, a.rpc)
    try:
        due = due_orders(chain, contract)
        if not due:
            return 0
        key = None if a.dry_run else guard.load_key(a)
        signer = None if a.dry_run else (a.account or key.account)
        if not a.dry_run and not signer:
            sys.exit("--account is required (the key file has no account_id)")
        for o in due[: a.max]:
            who, oid = o["owner"], o["order_id"]
            if a.dry_run:
                log("due", who, oid, f"{o['amount']} {o['token']} -> {o['recipient']}")
                continue
            h, res = chain.send(key, signer, contract, [guard.act_call(
                "execute_order", guard.json.dumps({"owner": who, "order_id": oid}).encode(), guard.GAS_CALL, 0)])
            err = guard.failure_text(res)
            top_failed = isinstance(res.get("status"), dict) and "Failure" in res["status"]
            if not err:
                log("paid", who, oid, f"{o['amount']} {o['token']} -> {o['recipient']} tx {h}")
            elif top_failed and any(s in err for s in ("not due yet", "no such order")):
                log("skipped", who, oid, f"{err} tx {h}")            # somebody else ran it first
            elif top_failed:
                log("failed", who, oid, f"{err} tx {h}")
            else:
                log("paid", who, oid, f"sent, but the transfer failed and was refunded to the vault ({err}) tx {h}")
    except (RuntimeError, guard.requests.RequestException) as e:
        log("error", detail=str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
