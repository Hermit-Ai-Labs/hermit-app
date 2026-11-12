#!/usr/bin/env python3
"""Hermit Guard judge script: no keys, no funds needed. Reads the live testnet deployment and checks the recorded run.

    .venv/bin/python near/guard-demo.py            # read-only: live vault + every recorded transaction re-checked on chain
    .venv/bin/python near/guard-demo.py --live     # also replays the attacks right now with a throwaway funded testnet account

What it does
  1. reads the contract on testnet with plain view calls (version, token list, vault, pockets, orders, receipts);
  2. fetches each transaction of a recorded run from the chain, and checks it did what the list says: that the
     contract paid inside the rules, and refused an over-cap spend, a non-allowed recipient, an over-daily-cap spend,
     a pocket key calling withdraw, a spend from a frozen vault, and a second run of a standing order in the same period;
  3. prints explorer links. With --live it creates a new throwaway testnet account (helper API) and does it all again.
Exit code 0 when every check matched, 1 if the chain disagrees with the list. Testnet only.
"""
import argparse, importlib.util, json, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard_cli", Path(__file__).resolve().parent / "guard.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

CONTRACT = "guard.hermit-guard-owner-1794512081.testnet"
OWNER = "hermit-guard-owner-1794512081.testnet"
SHOP = "hermit-guard-shop-1794512081.testnet"
OTHER = "other.hermit-guard-shop-1794512081.testnet"
TOKEN = "ft.hermit-guard-shop-1794512081.testnet"
WASM_SHA256 = "dd0ea418dfedf4ab9afde4d804202d06abd1d7459f6eb35131148e6eab4b1b64"   # contracts/guard/DEPLOYMENTS.md

# (what happened, signer account, tx hash, expected result, text the contract must have said)
#   paid     = the transaction succeeded
#   refused  = the contract panicked with the text below (nothing moved)
#   restored = the call went through, the token transfer failed, the callback put the money back (event payout_failed)
RUN = [
    ("deploy hermit_guard.wasm + init in one transaction (allowlist: near + test token)", CONTRACT, "6kc5RFbvxx25hDKSpwBfQcmFf6jaQovU8LyF9CKRLY5j", "paid", ""),
    ("deploy the test token + init (it requires registration, like USDC/USDT)", TOKEN, "HREUfioXLiU81YXjgtDQcR8cBz1woiewoXw4qFatYHdG", "paid", ""),
    ("register the guard contract itself with the token (storage_deposit 0.00125 NEAR, as guard.py deploy does)", CONTRACT, "EFeQDrjymo1ZuySQZnDJsF5KHCCTAE9wZaWnhNKKzNXG", "paid", ""),
    ("register the shop with the token", OWNER, "77a4c3ZbsYQrC3ai8o9a8QBfxaoYPAqzzkCmFeHoFxP9", "paid", ""),
    ("owner opens a vault with 3 NEAR", OWNER, "ES6bimQYS17ipBCwKacq2HzNbhWRyiGzoBZKvpnKAUkK", "paid", ""),
    ("owner deposits 1000 test tokens (ft_transfer_call from a registered owner)", OWNER, "DY64BZ59ac2MpiAjN6P75A2yrPJ1GwZarY9RCcb9pCqU", "paid", ""),
    ("owner adds a function-call key (spend/request only) to its OWN account", OWNER, "CprXWeHA1A33U9T3y9qtcQrBkktyvUUZCy5YdjaQLS7o", "paid", ""),
    ("owner creates pocket 'coffee' for that key: 0.5 per payment, 1 per day, shop only", OWNER, "CB6dfFpU4JnCAcF6WT8rfxCmehcYBEVV4X9eYk5hCGmn", "paid", ""),
    ("POCKET KEY spends 0.4 NEAR to the shop", OWNER, "Hq8QcxM7QV3Nq4nCd6T9Ngh5CFo1L8nyAw62xcxQXrZ6", "paid", ""),
    ("POCKET KEY tries 0.6 NEAR (over the per-payment cap)", OWNER, "7YBgHbwrGuuLUxSBDCLLucWQJ5AKocExbp9PMrdJtkrE", "refused", "over per-payment cap"),
    ("POCKET KEY tries 0.4 NEAR to a recipient that is not allowed", OWNER, "61SkkUNH9DWDy5kmU1d6V22TxapzdWsN9LJ95rfjJRK3", "refused", "recipient not allowed"),
    ("POCKET KEY spends 0.4 NEAR again (0.8 of 1.0 today)", OWNER, "DSXWGp7dfaA7ekZKfhBBN7DqEj4eXrWAyRZvd5p4TQwH", "paid", ""),
    ("POCKET KEY tries 0.4 NEAR (over the daily cap)", OWNER, "8P6M2oabyoSjETEj2MSyksHcaGg11msxXPdfKrF9CaFr", "refused", "over daily cap"),
    ("owner adds a deliberately MISCONFIGURED key that lists withdraw", OWNER, "3mgu697zTT4NoSBNq57Yxrafa76BUQwQxLaz4mAKx64B", "paid", ""),
    ("that key calls WITHDRAW (a pocket key cannot attach the 1 yocto)", OWNER, "CLZuHHyFg6T5vWQVjdf47ghpGxCFrQuoneUbZX1LdbwC", "refused", "exactly 1 yoctoNEAR"),
    ("owner deletes the misconfigured key", OWNER, "DHbBno2QNPhAtm3XHLnLUZ2GDQMH8m6YchSb4HNEymTE", "paid", ""),
    ("owner adds the key of the token pocket", OWNER, "BPCajEDwHXn6PNifR5XX3AzrbjJtj3JEbbyecVirs8jo", "paid", ""),
    ("owner creates pocket 'tokens' (100 per payment, 250 per day)", OWNER, "AEwro22oZrtZYB9QU4on8fYhHiERyspHtJVCEHP3eKm3", "paid", ""),
    ("POCKET KEY spends 100 test tokens to the registered shop", OWNER, "BATowC9T2peG2f6ag2xDWaPdYnXSEbuo7RZbCMYSCn6R", "paid", ""),
    ("POCKET KEY requests 1.5 NEAR (over its caps): stored, nothing paid", OWNER, "4Mc1ekkBtTmdCedEr4YwQdYmvLCMKJmTugLapQUPQ74E", "paid", ""),
    ("OWNER approves the request: 1.5 NEAR paid", OWNER, "7cCZ1YNKnE9zATwFTftoFwryqBD3eNGNEzvPbhbXwHEN", "paid", ""),
    ("owner creates pocket 'rent' (no key: for standing orders only)", OWNER, "6FcyJ2MxhBTt5jTCbVL37quzThv4aqnbwLtSBZBbUvi3", "paid", ""),
    ("owner creates a standing order (0.2 NEAR, hourly, 2 runs, first one due now)", OWNER, "AyBMXynZAwVRa5Gbsi6tsnUxUAkXMhPrRVotvkCFesBc", "paid", ""),
    ("A STRANGER triggers the due order: paid", OTHER, "AnFZp4EKrM2FFRocuiUdXP5VdRShWC1REHXweSDo15Lu", "paid", ""),
    ("the stranger triggers it again in the same period", OTHER, "7S1Pxk71MSbRW9Qa3CNLqaZ5eY5dV3uUhEgSz1zJEP4o", "refused", "order not due yet"),
    ("owner freezes the vault", OWNER, "8gcY1btMNG2DYkDbJ1xKZLqL6fpXm9mNBYaUVvrsnjPH", "paid", ""),
    ("POCKET KEY spends while frozen", OWNER, "3C5wo8wp95CKL33VkxRLSjXjdRpxXSQ1BcxcwqANXs5Q", "refused", "vault frozen"),
    ("owner withdraws 0.3 NEAR while frozen (always allowed)", OWNER, "2dyPKUvHrxdJ5TcLYKYHjg4ED82sgbTsoi1Lwcuks5pp", "paid", ""),
    ("owner unfreezes", OWNER, "ACesuR7WBLHqAzK6bzmpbU3iCr5jbzRr4B9isCkZvZxF", "paid", ""),
    ("POCKET KEY spends 100 test tokens to an unregistered account: transfer fails, money comes back", OWNER, "A5w1yEQvsHHdZQo8FHERkNXusuq4nNNrqhU15wYmYgHw", "restored", "not registered"),
    ("owner deposits 0.5 NEAR", OWNER, "CbpqtUPJDnrYQqRAk74NQEu2n8VBpXryF3HWgE9PjVXE", "paid", ""),
    ("owner creates a second order (0.1 NEAR, due now, one run) for the keeper", OWNER, "EDxkura45Sbi1xc5YSnKzKyLLpy5tXTTYjA8MeEQC5op", "paid", ""),
    ("KEEPER script (keeper.py) runs the due order", OTHER, "J26Qr5ykNAS75qfnVBsaQ6mu1Wf5zyjprPE9e2PFTunH", "paid", ""),
]
# Rejected by the NEAR runtime before they reach a block, so there is no transaction hash. Verbatim RPC answers:
RUNTIME_REFUSALS = [
    ("pocket key calls withdraw with 1 yocto attached", 'InvalidAccessKeyError: "DepositWithFunctionCall"  (a function-call key can never attach a deposit)'),
    ("pocket key calls withdraw with no deposit", 'InvalidAccessKeyError: {"MethodNameMismatch": {"method_name": "withdraw"}}  (the key allows only spend and request)'),
]


class Ctx:
    def __init__(self):
        self.chain = g.Chain("testnet")
        self.archive = g.Chain("testnet", "https://archival-rpc.testnet.near.org")
        self.ok = self.bad = self.unreachable = 0


def tx_result(c, h, signer):
    last = None
    for chain in (c.chain, c.archive):
        try:
            return chain.rpc("tx", {"tx_hash": h, "sender_account_id": signer, "wait_until": "FINAL"})
        except (RuntimeError, g.requests.RequestException) as e:
            last = e
    raise RuntimeError(str(last))


def judge(res, expect, text):
    """Returns (matches, one-line description)."""
    err = g.failure_text(res)
    top_failed = isinstance(res.get("status"), dict) and "Failure" in res["status"]
    events = [l for o in res["receipts_outcome"] for l in o["outcome"]["logs"] if "payout_failed" in l]
    if expect == "paid":
        return (not top_failed and not err, "succeeded" if not err else f"UNEXPECTED: {err}")
    if expect == "refused":
        return (top_failed and text in (err or ""), f"refused: {err}" if err else "UNEXPECTED: it succeeded")
    if expect == "restored":
        return (not top_failed and bool(events) and text in (err or ""), f"went through, transfer failed ({err}), contract restored it (payout_failed event)")
    return (False, "bad expectation")


def show_live_state(c):
    print("== live contract state (view calls on testnet) ==")
    ch = c.chain
    print(f"contract        {CONTRACT}")
    print(f"version         {ch.view(CONTRACT, 'version')}   tokens {ch.view(CONTRACT, 'get_tokens')}")
    print(f"vaults          {ch.view(CONTRACT, 'owners_count')}   storage deposit per vault {g.fmt_units('near', ch.view(CONTRACT, 'storage_cost'))}")
    acct = ch.account(CONTRACT)
    sha = g.b58decode(acct["code_hash"]).hex()
    print(f"contract code   sha256 {sha}  [{'matches' if sha == WASM_SHA256 else 'DIFFERS from'} the recorded build]")
    print(f"                storage {acct['storage_usage']} bytes   balance {g.fmt_units('near', acct['amount'])}")
    ns = argparse.Namespace(network="testnet", contract=CONTRACT, owner=OWNER, what=None)
    for what in ("vault", "pockets", "orders", "requests", "receipts"):
        print(f"-- {what} of {OWNER}")
        ns.what = what
        g.cmd_view(ns, ch)
    print()


def check_run(c):
    print("== recorded run: every transaction re-read from the chain ==")
    for i, (label, signer, h, expect, text) in enumerate(RUN, 1):
        try:
            res = tx_result(c, h, signer)
            good, line = judge(res, expect, text)
        except (RuntimeError, g.requests.RequestException) as e:
            c.unreachable += 1
            print(f"{i:>2}. [?] {label}\n      could not read {h}: {e}\n      {c.chain.link(h)}")
            continue
        c.ok += good
        c.bad += not good
        print(f"{i:>2}. [{'ok' if good else 'MISMATCH'}] {label}\n      {line}\n      {c.chain.link(h)}")
    print("\nRejected by the NEAR runtime itself (never reach a block, so no hash; verbatim RPC answers):")
    for label, answer in RUNTIME_REFUSALS:
        print(f"   - {label}: {answer}")
    print()


def live(c, fund_from=None):
    """Throwaway account, real transactions: pay inside the rules, then the same attacks. Everything is returned at the end."""
    print("== --live: replaying on a throwaway testnet account ==")
    ch = c.chain
    name = f"hermit-guard-demo-{int(time.time())}.testnet"
    owner, pocket = g.Key.generate(name), g.Key.generate(name)       # keys live in memory only
    r = g.requests.post(ch.cfg["helper"], json={"newAccountId": name, "newAccountPublicKey": owner.public}, timeout=60)
    if r.status_code == 200:
        print(f"created {name} (10 NEAR from the helper)")
    elif fund_from:
        # the helper rate-limits by IP (we hit "retry in 11 hours"); make the account under a funded testnet account instead
        parent = g.Key.parse(Path(fund_from).read_text())
        name = f"demo{int(time.time())}.{parent.account}"
        owner.account = pocket.account = name
        h, res = ch.send(parent, parent.account, name, [g.act_create_account(), g.act_transfer(3 * g.YOCTO), g.act_add_full_key(owner.public)])
        if g.failure_text(res):
            print("[?] could not create the throwaway account:", g.failure_text(res))
            return
        print(f"created {name} (3 NEAR from {parent.account}; helper said: {r.text[:60]})")
    else:
        print(f"[?] helper API refused ({r.status_code}: {r.text[:80]}); skipping --live (use --fund-from KEYFILE of a funded testnet account)")
        return
    time.sleep(3)
    checks = []

    def step(label, signer_key, receiver, actions, expect, text=""):
        h, res = ch.send(signer_key, name, receiver, actions)
        good, line = judge(res, expect, text)
        checks.append(good)
        print(f"[{'ok' if good else 'MISMATCH'}] {label}\n      {line}\n      {ch.link(h)}")

    def call(m, args, dep=0):
        return [g.act_call(m, json.dumps(args).encode(), g.GAS_CALL, dep)]

    storage = int(ch.view(CONTRACT, "storage_cost"))
    step("open a vault with 1 NEAR", owner, CONTRACT, call("open_vault", {}, storage + g.YOCTO), "paid")
    step("add a function-call key (spend/request) to the account itself", owner, name,
         [g.act_add_call_key(pocket.public, CONTRACT, ["spend", "request"], g.YOCTO // 2)], "paid")
    cfg = {"name": "demo", "public_key": pocket.public, "token": "near", "per_payment_cap": str(g.YOCTO // 2), "daily_cap": str(g.YOCTO),
           "allowed_recipients": [SHOP], "expires_at": None}
    step("create the pocket (0.5 per payment, 1 per day, shop only)", owner, CONTRACT, call("create_pocket", {"config": cfg}, 1), "paid")
    spend = lambda amt, to: call("spend", {"token": "near", "amount": str(int(amt * g.YOCTO)), "recipient": to, "reason": "demo"})
    step("pocket key pays 0.3 NEAR to the shop", pocket, CONTRACT, spend(0.3, SHOP), "paid")
    step("pocket key tries 0.6 NEAR (over the cap)", pocket, CONTRACT, spend(0.6, SHOP), "refused", "over per-payment cap")
    step("pocket key tries 0.3 NEAR to a stranger", pocket, CONTRACT, spend(0.3, OTHER), "refused", "recipient not allowed")
    for dep in (1, 0):
        try:
            ch.send(pocket, name, CONTRACT, call("withdraw", {"token": "near", "amount": None}, dep))
            checks.append(False)
            print(f"[MISMATCH] pocket key withdraw (deposit {dep}) was accepted!")
        except RuntimeError as e:
            checks.append("InvalidAccessKeyError" in str(e) or "INVALID_TRANSACTION" in str(e))
            print(f"[ok] pocket key calls withdraw (deposit {dep} yocto): rejected by the runtime: {str(e)[:150]}")
    step("owner withdraws everything", owner, CONTRACT, call("withdraw", {"token": "near", "amount": None}, 1), "paid")
    for _ in range(30):
        if ch.view(CONTRACT, "get_vault", {"owner": name})["pending_out"] == 0:
            break
        time.sleep(1)
    step("owner closes the vault (storage deposit comes back)", owner, CONTRACT, call("close_vault", {}, 1), "paid")
    print(f"live checks: {sum(checks)}/{len(checks)} matched")
    c.ok += sum(checks)
    c.bad += len(checks) - sum(checks)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--live", action="store_true", help="also replay the attacks now with a throwaway funded testnet account")
    ap.add_argument("--fund-from", help="with --live: key file of a funded testnet account, used if the faucet helper refuses (rate limit)")
    a = ap.parse_args()
    c = Ctx()
    try:
        show_live_state(c)
    except (RuntimeError, g.requests.RequestException) as e:
        print(f"[?] could not read the live state: {e}\n")
        c.unreachable += 1
    check_run(c)
    if a.live:
        live(c, a.fund_from)
    print(f"guard-demo: {c.ok} checks matched, {c.bad} mismatched, {c.unreachable} unreachable. "
          f"Contract {CONTRACT} on testnet: it paid inside the rules and refused over-cap, non-allowed, over-daily and pocket-key-withdraw attempts.")
    sys.exit(1 if c.bad else 0)


if __name__ == "__main__":
    main()
