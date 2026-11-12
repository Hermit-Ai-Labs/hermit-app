#!/usr/bin/env python3
"""Hermit Guard command line: read a vault, spend from a pocket, run standing orders, manage a vault.

    .venv/bin/python near/guard.py --selftest                       # offline checks of the transaction encoder
    .venv/bin/python near/guard.py view vault --owner alice.testnet
    .venv/bin/python near/guard.py --key-file pocket.json spend --token near --amount 0.5 --to shop.testnet --reason coffee
    .venv/bin/python near/guard.py --key-file owner.json create-pocket --name coffee --token near --per-payment 1 --daily 3 \
                                   --recipient shop.testnet --key-out pocket.json
    .venv/bin/python near/guard.py --help

Network: testnet unless you pass `--network mainnet` AND `--contract <id>` (there is no default contract on mainnet).
Keys: `--key-file PATH` (near-cli JSON {"account_id","public_key","private_key"} or a bare "ed25519:..." string),
or the env var GUARD_KEY_FILE (path) or GUARD_KEY (the key itself). A key is never printed.
Amounts: for the token "near" they are NEAR (decimals allowed, e.g. 0.5); for any other token they are integer base units.

Only `requests` and `cryptography` (near/requirements.txt) are used. The Borsh transaction encoder is in this file and is
checked by --selftest against the bytes, hash and signature that near-api-js produced (the vector in
Packages/HermitKit/Tests/HermitWalletTests/NearIntentsTests.swift).
"""
import argparse, base64, hashlib, json, os, struct, sys, time
from decimal import Decimal
from pathlib import Path

import requests
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, PublicFormat, NoEncryption

NETWORKS = {
    "testnet": {"rpc": "https://test.rpc.fastnear.com", "explorer": "https://testnet.nearblocks.io/txns/",
                "helper": "https://helper.nearprotocol.com/account"},
    "mainnet": {"rpc": "https://free.rpc.fastnear.com", "explorer": "https://nearblocks.io/txns/", "helper": None},
}
# Set after the testnet deployment (see contracts/guard/DEPLOYMENTS.md). Mainnet has no default on purpose.
DEFAULT_CONTRACT = {"testnet": "guard.hermit-guard-owner-1794512081.testnet", "mainnet": None}
YOCTO = 10 ** 24
TGAS = 10 ** 12
GAS_CALL = 150 * TGAS      # the contract refuses payout calls with less than 120 TGas attached; 150 leaves headroom
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


# ------------------------------------------------------------------ base58 / borsh

def b58encode(b: bytes) -> str:
    n, out = int.from_bytes(b, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + out


def b58decode(s: str) -> bytes:
    n = 0
    for ch in s:
        n = n * 58 + B58.index(ch)
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\0" * (len(s) - len(s.lstrip("1"))) + body


def u32(n): return struct.pack("<I", n)
def u64(n): return struct.pack("<Q", n)
def u128(n): return n.to_bytes(16, "little")
def bstr(s): b = s.encode(); return u32(len(b)) + b
def bvec(b): return u32(len(b)) + bytes(b)


def pubkey_bytes(pub: str) -> bytes:
    kind, _, data = pub.partition(":")
    if kind != "ed25519":
        raise SystemExit("only ed25519 keys are supported")
    raw = b58decode(data)
    if len(raw) != 32:
        raise SystemExit("bad public key length")
    return b"\x00" + raw


class Act(bytes):
    """One serialized action plus a human description (shown before anything is sent on mainnet)."""
    desc = ""
    deposit = 0


def _act(raw: bytes, desc: str, deposit: int = 0) -> "Act":
    a = Act(raw)
    a.desc, a.deposit = desc, deposit
    return a


# Actions (NEAR protocol enum order): CreateAccount 0, DeployContract 1, FunctionCall 2, Transfer 3, Stake 4, AddKey 5, DeleteKey 6
def act_create_account(): return _act(b"\x00", "CreateAccount")
def act_deploy(wasm: bytes): return _act(b"\x01" + bvec(wasm), f"DeployContract {len(wasm)} bytes, sha256 {hashlib.sha256(wasm).hexdigest()}")


def act_call(method, args: bytes, gas, deposit):
    shown = args.decode("utf8", "replace")
    return _act(b"\x02" + bstr(method) + bvec(args) + u64(gas) + u128(deposit),
                f"FunctionCall {method}({shown[:300]}{'...' if len(shown) > 300 else ''}) gas {gas // TGAS} TGas, deposit {deposit / YOCTO:.6f} NEAR", deposit)


def act_transfer(deposit): return _act(b"\x03" + u128(deposit), f"Transfer {deposit / YOCTO:.6f} NEAR", deposit)
def act_delete_key(pub): return _act(b"\x06" + pubkey_bytes(pub), f"DeleteKey {pub}")
def act_add_full_key(pub): return _act(b"\x05" + pubkey_bytes(pub) + u64(0) + b"\x01", f"AddKey FULL ACCESS {pub}")


def act_add_call_key(pub, receiver, methods, allowance):
    perm = b"\x00" + (b"\x01" + u128(allowance) if allowance is not None else b"\x00") + bstr(receiver) \
        + u32(len(methods)) + b"".join(bstr(m) for m in methods)
    return _act(b"\x05" + pubkey_bytes(pub) + u64(0) + perm,
                f"AddKey function-call {pub} receiver {receiver} methods {','.join(methods)} allowance {(allowance or 0) / YOCTO:.4f} NEAR")


def serialize_tx(signer, pub, nonce, receiver, block_hash: bytes, actions) -> bytes:
    return bstr(signer) + pubkey_bytes(pub) + u64(nonce) + bstr(receiver) + block_hash + u32(len(actions)) + b"".join(actions)


def tx_hash(tx: bytes) -> bytes:
    return hashlib.sha256(tx).digest()


def signed_tx(tx: bytes, key: Ed25519PrivateKey) -> bytes:
    return tx + b"\x00" + key.sign(tx_hash(tx))


# ------------------------------------------------------------------ keys

class Key:
    def __init__(self, seed: bytes, account=None):
        self.sk = Ed25519PrivateKey.from_private_bytes(seed)
        self.pub = self.sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.account = account

    @property
    def public(self): return "ed25519:" + b58encode(self.pub)

    @staticmethod
    def parse(text: str, account=None):
        text = text.strip()
        if text.startswith("{"):
            j = json.loads(text)
            account = account or j.get("account_id")
            text = j.get("private_key") or j.get("secret_key") or ""
        raw = b58decode(text.split(":", 1)[-1])
        if len(raw) not in (32, 64):
            raise SystemExit("key must be an ed25519 secret key (32 or 64 bytes, base58)")
        return Key(raw[:32], account)

    @staticmethod
    def generate(account=None):
        return Key(Ed25519PrivateKey.generate().private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()), account)

    def save(self, path: str, account: str):
        seed = self.sk.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
        body = json.dumps({"account_id": account, "public_key": self.public, "private_key": "ed25519:" + b58encode(seed + self.pub)})
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)   # never overwrites, never world-readable
        with os.fdopen(fd, "w") as f:
            f.write(body)


def load_key(args, account=None) -> Key:
    path = getattr(args, "key_file", None) or os.environ.get("GUARD_KEY_FILE")
    if path:
        return Key.parse(Path(path).read_text(), account)
    if os.environ.get("GUARD_KEY"):
        return Key.parse(os.environ["GUARD_KEY"], account)
    raise SystemExit("no key: pass --key-file PATH or set GUARD_KEY_FILE / GUARD_KEY")


# ------------------------------------------------------------------ rpc

class Chain:
    def __init__(self, network, rpc=None):
        self.cfg = NETWORKS[network]
        self.network = network
        self.rpc_url = rpc or self.cfg["rpc"]
        self.yes = False

    def rpc(self, method, params):
        for attempt in range(6):                        # public RPCs answer 429 when busy: wait and retry
            r = requests.post(self.rpc_url, json={"jsonrpc": "2.0", "id": "guard", "method": method, "params": params}, timeout=60)
            if r.status_code not in (429, 502, 503):
                break
            time.sleep(2 * (attempt + 1))
        r.raise_for_status()
        j = r.json()
        if j.get("error"):
            e = j["error"]
            cause = e.get("cause") or {}
            d = e.get("data")
            detail = d if isinstance(d, str) else (json.dumps(d) if d else (json.dumps(cause.get("info")) if cause.get("info") else ""))
            raise RuntimeError(" ".join(x for x in [cause.get("name") or e.get("name") or json.dumps(e), detail] if x))
        return j["result"]

    def view(self, contract, method, args=None):
        r = self.rpc("query", {"request_type": "call_function", "finality": "final", "account_id": contract, "method_name": method,
                               "args_base64": base64.b64encode(json.dumps(args or {}).encode()).decode()})
        if r.get("error"):
            raise RuntimeError(r["error"])
        return json.loads(bytes(r["result"]) or b"null")

    def account(self, account_id):
        return self.rpc("query", {"request_type": "view_account", "finality": "final", "account_id": account_id})

    def confirm(self, signer, receiver, actions):
        """Mainnet writes: print exactly what will be sent and refuse unless --yes was given."""
        if self.network != "mainnet":
            return
        total = sum(getattr(a, "deposit", 0) for a in actions)
        print("MAINNET TRANSACTION (real funds)", file=sys.stderr)
        print(f"  from     {signer}\n  to       {receiver}", file=sys.stderr)
        for a in actions:
            print("  action  ", getattr(a, "desc", "?"), file=sys.stderr)
        print(f"  NEAR attached in total: {total / YOCTO:.6f}", file=sys.stderr)
        if not self.yes:
            print("NOT SENT. Add --yes (before the command name) to send this for real.", file=sys.stderr)
            raise SystemExit(2)

    def send(self, key: Key, signer, receiver, actions):
        suffix_bad = ".near" if self.network == "testnet" else ".testnet"
        for who in (signer, receiver):
            if who.endswith(suffix_bad):
                raise SystemExit(f"refusing: {who} looks like a {'mainnet' if self.network == 'testnet' else 'testnet'} account but --network is {self.network}")
        self.confirm(signer, receiver, actions)
        ak = self.rpc("query", {"request_type": "view_access_key", "finality": "final", "account_id": signer, "public_key": key.public})
        block = self.rpc("block", {"finality": "final"})["header"]["hash"]
        tx = serialize_tx(signer, key.public, ak["nonce"] + 1, receiver, b58decode(block), actions)
        res = self.rpc("send_tx", {"signed_tx_base64": base64.b64encode(signed_tx(tx, key.sk)).decode(), "wait_until": "FINAL"})
        return b58encode(tx_hash(tx)), res

    def link(self, h): return self.cfg["explorer"] + h


def failure_text(res):
    """First failure message found in a transaction result, or None."""
    outcomes = [res.get("transaction_outcome", {})] + list(res.get("receipts_outcome", []))
    for o in outcomes:
        st = (o.get("outcome") or {}).get("status")
        if isinstance(st, dict) and "Failure" in st:
            f = st["Failure"]
            try:
                ex = f["ActionError"]["kind"]["FunctionCallError"]
                if "ExecutionError" in ex:
                    return ex["ExecutionError"]
                return json.dumps(ex)
            except (KeyError, TypeError):
                return json.dumps(f)
    return None


def report(chain, h, res, quiet=False):
    err = failure_text(res)
    logs = [l for o in res.get("receipts_outcome", []) for l in o["outcome"].get("logs", []) if l.startswith("EVENT_JSON:")]
    top_failed = isinstance(res.get("status"), dict) and "Failure" in res["status"]
    if err and not top_failed:
        # the call itself went through; a later transfer failed and the contract's callback put the money back
        print("OK, but a transfer receipt failed and the contract restored it: " + err)
        err = None
    else:
        print(("REFUSED/FAILED: " + err) if err else "OK")
    print("tx    ", h)
    print("link  ", chain.link(h))
    if not quiet:
        for l in logs:
            print("event ", l[len("EVENT_JSON:"):])
    return 1 if err else 0


# ------------------------------------------------------------------ amounts

def to_units(token, text):
    if token == "near":
        return int(Decimal(text) * YOCTO)
    if not str(text).isdigit():
        raise SystemExit("amounts of non-NEAR tokens are integer base units")
    return int(text)


def fmt_units(token, n):
    n = int(n)
    return f"{Decimal(n) / YOCTO:f} NEAR".replace(".000000000000000000000000", "") if token == "near" else f"{n} ({token})"


def ns_to_text(ns):
    ns = int(ns)
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(ns / 1e9)) if ns else "-"


# ------------------------------------------------------------------ commands

def contract_id(args):
    c = args.contract or DEFAULT_CONTRACT.get(args.network)
    if not c:
        raise SystemExit(f"--contract is required on {args.network}")
    return c


def call_guard(args, chain, key, signer, method, params, deposit=0, gas=GAS_CALL):
    c = contract_id(args)
    h, res = chain.send(key, signer, c, [act_call(method, json.dumps(params).encode(), gas, deposit)])
    return report(chain, h, res)


def signer_for(args, key):
    acct = args.account or key.account
    if not acct:
        raise SystemExit("--account is required (the key file has no account_id)")
    return acct


def cmd_view(args, chain):
    c, owner = contract_id(args), args.owner
    what = args.what
    if what == "info":
        print("contract ", c, "\nversion  ", chain.view(c, "version"), "\ntokens   ", chain.view(c, "get_tokens"),
              "\nowners   ", chain.view(c, "owners_count"), "\nstorage deposit", fmt_units("near", chain.view(c, "storage_cost")),
              "\ncode sha256", b58decode(chain.account(c)["code_hash"]).hex())
        return 0
    if what == "token-bounds":
        for t in [t for t in (args.tokens.split(",") if args.tokens else chain.view(c, "get_tokens")) if t != "near"]:
            b = chain.view(t, "storage_balance_bounds")
            reg = chain.view(t, "storage_balance_of", {"account_id": c})
            print(f"{t}: storage_balance_bounds min {fmt_units('near', b['min'])} max {fmt_units('near', b['max']) if b.get('max') else 'none'};"
                  f" guard registered: {'yes, balance ' + fmt_units('near', reg['total']) if reg else 'NO'}")
        return 0
    if what == "due":
        print(json.dumps(chain.view(c, "due_orders", {"from_index": 0, "limit": 20}), indent=1))
        return 0
    if not owner:
        raise SystemExit("--owner is required")
    if what == "vault":
        v = chain.view(c, "get_vault", {"owner": owner})
        if not v:
            print("no vault for", owner)
            return 0
        print(f"vault of {owner}: {'FROZEN' if v['frozen'] else 'active'}, {v['pockets']} pockets, {v['orders']} orders, "
              f"{v['requests']} requests, {v['receipts_total']} receipts, {v['pending_out']} payouts in flight")
        for b in v["balances"]:
            print("  balance", fmt_units(b["token"], b["amount"]))
        return 0
    if what == "pockets":
        for p in chain.view(c, "get_pockets", {"owner": owner}):
            t = p["token"]
            print(f"- {p['name']}: {t}, per payment {fmt_units(t, p['per_payment_cap'])}, per day {fmt_units(t, p['daily_cap'])}, "
                  f"spent in window {fmt_units(t, p['spent'])}, {'PAUSED, ' if p['paused'] else ''}"
                  f"expires {ns_to_text(p['expires_at']) if p['expires_at'] else 'never'}, "
                  f"recipients {', '.join(p['allowed_recipients']) or 'any'}, key {p['public_key'] or 'none'}")
        return 0
    if what == "orders":
        for o in chain.view(c, "get_orders", {"owner": owner}):
            print(f"- #{o['id']} {o['pocket']}: {fmt_units(o['token'], o['amount'])} to {o['recipient']} every {o['interval_seconds']}s, "
                  f"next {ns_to_text(o['next_due_ns'])}, remaining {o['remaining'] if o['remaining'] is not None else 'unlimited'}, {o['memo']!r}")
        return 0
    if what == "requests":
        for r in chain.view(c, "get_requests", {"owner": owner}):
            print(f"- #{r['id']} {r['pocket']}: {fmt_units(r['token'], r['amount'])} to {r['recipient']} at {ns_to_text(r['created_ns'])}: {r['reason']!r}")
        return 0
    if what == "receipts":
        for r in chain.view(c, "get_receipts", {"owner": owner}):
            print(f"- #{r['id']} {ns_to_text(r['time'])} {r['kind']:<8} {fmt_units(r['token'], r['amount'])} to {r['recipient']} "
                  f"[{r['pocket'] or '-'}] {'ok' if r['ok'] else 'FAILED (refunded)'} {r['reason']!r}")
        return 0
    raise SystemExit("unknown view")


def cmd_spend(args, chain, request=False):
    key = load_key(args)
    signer = signer_for(args, key)
    p = {"token": args.token, "amount": str(to_units(args.token, args.amount)), "recipient": args.to, "reason": args.reason}
    return call_guard(args, chain, key, signer, "request" if request else "spend", p)


def cmd_execute(args, chain):
    key = load_key(args)
    return call_guard(args, chain, key, signer_for(args, key), "execute_order", {"owner": args.owner, "order_id": args.order_id})


def owner_call(args, chain, method, params, deposit=1):
    key = load_key(args)
    return call_guard(args, chain, key, signer_for(args, key), method, params, deposit)


def cmd_open(args, chain):
    from_near = int(Decimal(args.near) * YOCTO)
    storage = int(chain.view(contract_id(args), "storage_cost"))
    return owner_call(args, chain, "open_vault", {}, storage + from_near)


def cmd_create_pocket(args, chain):
    key = load_key(args)
    owner = signer_for(args, key)
    pocket_pub = args.public_key
    if args.key_out and not pocket_pub:
        pk = Key.generate()
        pk.save(args.key_out, owner)                       # saved BEFORE it is added on chain, so it can't get lost
        pocket_pub = pk.public
        print("pocket key written to", args.key_out, "(mode 600); public key", pocket_pub)
        allowance = int(Decimal(args.allowance) * YOCTO)
        h, res = chain.send(key, owner, owner, [act_add_call_key(pocket_pub, contract_id(args), ["spend", "request"], allowance)])
        if report(chain, h, res, quiet=True):
            return 1
    cfg = {"name": args.name, "public_key": pocket_pub, "token": args.token,
           "per_payment_cap": str(to_units(args.token, args.per_payment)), "daily_cap": str(to_units(args.token, args.daily)),
           "allowed_recipients": args.recipient or [],
           "expires_at": str(int((time.time() + args.expires_in_hours * 3600) * 1e9)) if args.expires_in_hours else None}
    return call_guard(args, chain, key, owner, "create_pocket", {"config": cfg}, 1)


def cmd_create_order(args, chain):
    first = str(int((time.time() + args.first_in_seconds) * 1e9)) if args.first_in_seconds is not None else None
    return owner_call(args, chain, "create_order", {
        "pocket": args.pocket, "amount": str(to_units(args.token, args.amount)), "recipient": args.to,
        "interval_seconds": args.interval_seconds, "first_due_ns": first, "remaining": args.count, "memo": args.memo})


def cmd_withdraw(args, chain):
    amount = None if args.all else str(to_units(args.token, args.amount))
    return owner_call(args, chain, "withdraw", {"token": args.token, "amount": amount})


def cmd_deposit(args, chain):
    if args.token == "near":
        return owner_call(args, chain, "deposit_near", {}, int(Decimal(args.amount) * YOCTO))
    key = load_key(args)
    signer = signer_for(args, key)
    h, res = chain.send(key, signer, args.token, [act_call("ft_transfer_call", json.dumps(
        {"receiver_id": contract_id(args), "amount": str(to_units(args.token, args.amount)), "msg": ""}).encode(), 200 * TGAS, 1)])
    return report(chain, h, res)


def cmd_new_account(args, chain):
    helper = chain.cfg["helper"]
    if not helper:
        raise SystemExit("new-account only exists on testnet")
    k = Key.generate()
    r = requests.post(helper, json={"newAccountId": args.name, "newAccountPublicKey": k.public}, timeout=60)
    if r.status_code != 200:
        raise SystemExit(f"helper refused ({r.status_code}): {r.text[:200]}")
    k.save(args.key_out, args.name)
    print("created", args.name, "- key written to", args.key_out, "(mode 600)")
    return 0


def cmd_keygen(args, chain):
    k = Key.generate()
    k.save(args.out, args.account_id)
    print("new key written to", args.out, "(mode 600); public key", k.public)
    return 0


def cmd_transfer(args, chain):
    key = load_key(args)
    h, res = chain.send(key, signer_for(args, key), args.to, [act_transfer(int(Decimal(args.near) * YOCTO))])
    return report(chain, h, res)


def cmd_call(args, chain):
    key = load_key(args)
    h, res = chain.send(key, signer_for(args, key), args.to, [act_call(args.method, args.args.encode(), int(args.gas_tgas) * TGAS, int(args.deposit_yocto))])
    return report(chain, h, res)


def register_tokens(args, chain, key, acct, contract):
    """Register the guard contract itself with every allowlisted NEP-141 (the real ones refuse transfers to unregistered accounts)."""
    rc = 0
    for t in [t for t in chain.view(contract, "get_tokens") if t != "near"]:
        if chain.view(t, "storage_balance_of", {"account_id": contract}):
            print(f"{t}: guard already registered")
            continue
        need = int(chain.view(t, "storage_balance_bounds")["min"])
        h, res = chain.send(key, acct, t, [act_call("storage_deposit", json.dumps({"account_id": contract, "registration_only": True}).encode(), 30 * TGAS, need)])
        print(f"register with {t} ({need / YOCTO:.5f} NEAR):")
        rc |= report(chain, h, res)
    return rc


def cmd_register_tokens(args, chain):
    key = load_key(args)
    return register_tokens(args, chain, key, signer_for(args, key), contract_id(args))


def cmd_create_account(args, chain):
    """Create a sub-account of the key's account (name must end with .<signer>) and fund it. Full-access key = --public-key."""
    key = load_key(args)
    parent = signer_for(args, key)
    if not args.name.endswith("." + parent):
        raise SystemExit(f"a sub-account name must end with .{parent}")
    h, res = chain.send(key, parent, args.name, [act_create_account(), act_transfer(int(Decimal(args.near) * YOCTO)), act_add_full_key(args.public_key)])
    return report(chain, h, res)


def cmd_deploy(args, chain):
    """DeployContract + `new` in ONE transaction signed by the contract account (so nobody can init it first)."""
    key = load_key(args)
    acct = signer_for(args, key)
    wasm = Path(args.wasm).read_bytes()
    print(f"wasm {len(wasm)} bytes, sha256 {hashlib.sha256(wasm).hexdigest()}")
    init = args.init_json or json.dumps({"tokens": args.tokens.split(",")})
    json.loads(init)
    actions = [act_deploy(wasm)] + ([] if args.no_init else [act_call("new", init.encode(), 30 * TGAS, 0)])
    h, res = chain.send(key, acct, acct, actions)
    rc = report(chain, h, res)
    if rc == 0 and not args.no_init and not args.no_register:
        rc |= register_tokens(args, chain, key, acct, acct)
    return rc


def cmd_add_key(args, chain):
    key = load_key(args)
    acct = signer_for(args, key)
    act = act_add_call_key(args.public_key, args.receiver, args.methods.split(","), int(Decimal(args.allowance) * YOCTO)) \
        if not args.full_access else act_add_full_key(args.public_key)
    h, res = chain.send(key, acct, acct, [act])
    return report(chain, h, res)


def cmd_delete_key(args, chain):
    key = load_key(args)
    acct = signer_for(args, key)
    h, res = chain.send(key, acct, acct, [act_delete_key(args.public_key)])
    return report(chain, h, res)


# ------------------------------------------------------------------ selftest (offline)

SELFTEST_SK = "F1kPR175szkGxEL52A9H6Z5ocS2BtaipprK2Hiob9DjGzHTkScrBb1yt44baXPZ3LxyHcsTPdBjHmn6zx147txH"  # public test phrase "abandon x11 about"
SELFTEST_BLOCK = "4reLvkAWfqk5fsqio1KLudk46cqRz9erQdaHkWZKMJDZ"
SELFTEST_IMPLICIT = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"


def _refuses_without_yes():
    ch = Chain("mainnet")
    import contextlib, io
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            ch.confirm("a.near", "b.near", [act_transfer(1)])
    except SystemExit as e:
        return e.code == 2
    return False


def selftest():
    k = Key.parse("ed25519:" + SELFTEST_SK)
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"[{'PASS' if good else 'FAIL'}] {name}")
        if not good:
            print("   got ", got, "\n   want", want)

    check("base58 round trip", b58decode(b58encode(b"\0\0hello")), b"\0\0hello")
    check("public key = implicit account of the test phrase", k.pub.hex(), SELFTEST_IMPLICIT)
    check("public key base58", k.public, "ed25519:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25")
    block = b58decode(SELFTEST_BLOCK)
    # Vector 1: transfer of 1.5 NEAR to bob.near (NearTests.testTransferMatchesNearApiJs)
    t1 = serialize_tx(SELFTEST_IMPLICIT, k.public, 123456789, "bob.near", block, [act_transfer(1500000000000000000000000)])
    check("transfer bytes match near-api-js", t1.hex(),
          "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132"
          "005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b070000000008000000626f622e6e656172"
          "394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c0100000003000080716433b629a33d010000000000")
    check("transfer tx hash", b58encode(tx_hash(t1)), "Dx1qLDXqinY5Mo5q9ZkG3Mzg7phWXpGU1szK3M1JTDCR")
    js = base64.b64decode("QAAAADU1MTBlMmI0NGNhZTZlYjgwN2UzZTBlNDVkNTc5ZGRhMDU4YzI3NGFiY2JhMTVlNWNiODQ2MzZmNWQxZWU0MTIAVRDitEyubrgH4+DkXVed2gWMJ0q8uhXly4Rjb10e5BIVzVsHAAAAAAgAAABib2IubmVhcjlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAAAKFsNyvmBU9/q5DL0NsUkh0qkT1HOjc0yx3mISDOg75m16Um6Uf1dzDSl+Wogd6q3JlPvp1+FoZRPhOxDLnMNgw=")
    check("signed transaction equals near-api-js byte for byte (ed25519 is deterministic)", signed_tx(t1, k.sk), js)
    try:
        Ed25519PublicKey.from_public_bytes(k.pub).verify(js[len(t1) + 1:], tx_hash(t1))
        check("near-api-js signature verifies with our hash", True, True)
    except InvalidSignature:
        check("near-api-js signature verifies with our hash", False, True)
    # Vector 2: storage_deposit + ft_transfer on USDC (NearTests.testFtTransferWithStorageMatchesNearApiJs)
    usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    t2 = serialize_tx(SELFTEST_IMPLICIT, k.public, 123456789, usdc, block, [
        act_call("storage_deposit", b'{"account_id":"bob.near","registration_only":true}', 30 * TGAS, 1250000000000000000000),
        act_call("ft_transfer", b'{"receiver_id":"bob.near","amount":"2500000"}', 30 * TGAS, 1)])
    check("function-call transaction hash matches near-api-js", b58encode(tx_hash(t2)), "2852HwiCVMHsVDhexEsSy2LCeXiy6MWgUpg39EGqPLuy")
    # Add-key layout (NEAR protocol spec): tag 5, key, nonce 0, permission 0 {allowance Some(u128), receiver, methods}
    ak = act_add_call_key(k.public, "g.testnet", ["spend", "request"], 10 ** 24)
    want = (b"\x05" + b"\x00" + k.pub + u64(0) + b"\x00" + b"\x01" + u128(10 ** 24) + u32(9) + b"g.testnet" + u32(2)
            + u32(5) + b"spend" + u32(7) + b"request")
    check("add function-call key layout", ak, want)
    check("add full-access key layout", act_add_full_key(k.public), b"\x05\x00" + k.pub + u64(0) + b"\x01")
    check("delete key layout", act_delete_key(k.public), b"\x06\x00" + k.pub)
    check("create account layout", act_create_account(), b"\x00")
    check("mainnet write without --yes is refused", _refuses_without_yes(), True)
    check("deploy action layout", act_deploy(b"\0asm"), b"\x01" + u32(4) + b"\0asm")
    # key file handling never needs the account in the string form
    check("bare key string parses", Key.parse("ed25519:" + SELFTEST_SK).public, k.public)
    print("selftest:", "all passed" if ok else "FAILED")
    return 0 if ok else 1


# ------------------------------------------------------------------ main

def build_parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--network", choices=["testnet", "mainnet"], default="testnet", help="default testnet; mainnet only when you say so")
    ap.add_argument("--rpc", help="override the RPC url")
    ap.add_argument("--contract", help="guard contract account id (default: the testnet deployment; required on mainnet)")
    ap.add_argument("--key-file", help="key file (or env GUARD_KEY_FILE / GUARD_KEY)")
    ap.add_argument("--account", help="account the key belongs to (default: account_id inside the key file)")
    ap.add_argument("--yes", action="store_true", help="mainnet only: really send. Without it a mainnet write prints what it would send and stops")
    ap.add_argument("--selftest", action="store_true", help="check the transaction encoder offline and exit")
    sub = ap.add_subparsers(dest="cmd")

    def add(name, fn, help, **kw):
        p = sub.add_parser(name, help=help)
        p.set_defaults(fn=fn)
        return p

    p = add("view", cmd_view, "read a vault (no key needed)")
    p.add_argument("what", choices=["info", "vault", "pockets", "orders", "requests", "receipts", "due", "token-bounds"])
    p.add_argument("--owner")
    p.add_argument("--tokens", help="token-bounds: comma separated token ids (default: the contract allowlist)")
    for name, fn, hp in [("spend", lambda a, c: cmd_spend(a, c), "spend from a pocket (use the pocket's key file)"),
                         ("request", lambda a, c: cmd_spend(a, c, True), "ask the owner for a payment the caps do not allow (pocket key)")]:
        p = add(name, fn, hp)
        p.add_argument("--token", default="near")
        p.add_argument("--amount", required=True)
        p.add_argument("--to", required=True)
        p.add_argument("--reason", default="")
    p = add("execute-order", cmd_execute, "trigger a due standing order (any key)")
    p.add_argument("--owner", required=True)
    p.add_argument("--order-id", type=int, required=True)

    p = add("open", cmd_open, "owner: open a vault (pays the storage deposit)")
    p.add_argument("--near", default="0", help="extra NEAR to put in the vault right away")
    p = add("deposit", cmd_deposit, "owner: fund the vault")
    p.add_argument("--token", default="near")
    p.add_argument("--amount", required=True)
    p = add("create-pocket", cmd_create_pocket, "owner: create a pocket; with --key-out also makes and adds its function-call key")
    p.add_argument("--name", required=True)
    p.add_argument("--token", default="near")
    p.add_argument("--per-payment", required=True)
    p.add_argument("--daily", required=True)
    p.add_argument("--recipient", action="append", help="allowed recipient (repeat; none = anyone)")
    p.add_argument("--expires-in-hours", type=float)
    p.add_argument("--key-out", help="write a NEW pocket key here (mode 600) and add it to your account")
    p.add_argument("--public-key", help="use an existing public key instead (you add it yourself)")
    p.add_argument("--allowance", default="1", help="gas allowance of the function-call key in NEAR (default 1)")
    p = add("create-order", cmd_create_order, "owner: standing order")
    p.add_argument("--pocket", required=True)
    p.add_argument("--token", default="near")
    p.add_argument("--amount", required=True)
    p.add_argument("--to", required=True)
    p.add_argument("--interval-seconds", type=int, required=True)
    p.add_argument("--first-in-seconds", type=float, help="first run this many seconds from now (default: one interval)")
    p.add_argument("--count", type=int, help="stop after this many runs")
    p.add_argument("--memo", default="")
    for name, m in [("cancel-order", "cancel_order"), ("approve", "approve"), ("reject", "reject")]:
        p = add(name, (lambda m: lambda a, c: owner_call(a, c, m, {"order_id": a.id} if m == "cancel_order" else {"request_id": a.id}))(m), f"owner: {name}")
        p.add_argument("--id", type=int, required=True)
    for name in ["freeze", "unfreeze", "close-vault"]:
        add(name, (lambda n: lambda a, c: owner_call(a, c, n.replace("-", "_"), {}))(name), f"owner: {name}")
    for name, m in [("pause-pocket", "pause_pocket"), ("resume-pocket", "resume_pocket"), ("remove-pocket", "remove_pocket")]:
        p = add(name, (lambda m: lambda a, c: owner_call(a, c, m, {"name": a.name}))(m), f"owner: {name}")
        p.add_argument("--name", required=True)
    p = add("withdraw", cmd_withdraw, "owner: withdraw to your own account")
    p.add_argument("--token", default="near")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--amount")
    g.add_argument("--all", action="store_true")

    p = add("new-account", cmd_new_account, "testnet only: create a funded account through the helper API")
    p.add_argument("--name", required=True)
    p.add_argument("--key-out", required=True)
    p = add("register-tokens", cmd_register_tokens, "register the contract with every allowlisted NEP-141 token (pays each token's minimum storage deposit)")
    p = add("create-account", cmd_create_account, "create and fund a sub-account of the key's account")
    p.add_argument("--name", required=True)
    p.add_argument("--public-key", required=True, help="full-access key of the new account")
    p.add_argument("--near", required=True, help="NEAR to send to the new account")
    p = add("keygen", cmd_keygen, "make a new ed25519 key file (mode 600)")
    p.add_argument("--out", required=True)
    p.add_argument("--account-id", required=True, help="account the key is meant for (stored in the file)")
    p = add("transfer", cmd_transfer, "send NEAR from the key's account")
    p.add_argument("--to", required=True)
    p.add_argument("--near", required=True)
    p = add("call", cmd_call, "raw function call")
    p.add_argument("--to", required=True)
    p.add_argument("--method", required=True)
    p.add_argument("--args", default="{}")
    p.add_argument("--deposit-yocto", default="0")
    p.add_argument("--gas-tgas", default="100")
    p = add("deploy", cmd_deploy, "deploy a wasm to the key's account and run `new` in the same transaction")
    p.add_argument("--wasm", required=True)
    p.add_argument("--tokens", default="near", help="comma separated allowlist, e.g. near,usdc.fakes.testnet")
    p.add_argument("--no-register", action="store_true", help="do not register the contract with the allowlisted tokens after init")
    p.add_argument("--no-init", action="store_true", help="only replace the code of an account that is already initialised (state is kept)")
    p.add_argument("--init-json", help="arguments of `new` as JSON (for the test token: {\"owner_id\":...,\"total_supply\":...})")
    p = add("add-key", cmd_add_key, "add an access key to the key's own account")
    p.add_argument("--public-key", required=True)
    p.add_argument("--full-access", action="store_true")
    p.add_argument("--receiver", help="function-call key receiver")
    p.add_argument("--methods", default="spend,request")
    p.add_argument("--allowance", default="1")
    p = add("delete-key", cmd_delete_key, "delete an access key of the key's own account")
    p.add_argument("--public-key", required=True)
    return ap


def main():
    ap = build_parser()
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    if not getattr(args, "fn", None):
        ap.print_help()
        sys.exit(2)
    chain = Chain(args.network, args.rpc)
    chain.yes = args.yes
    if args.network == "mainnet":
        print("NOTE: mainnet. Real funds.", file=sys.stderr)
    try:
        sys.exit(args.fn(args, chain) or 0)
    except (RuntimeError, requests.RequestException) as e:
        print("error:", e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
