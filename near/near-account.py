#!/usr/bin/env python3
"""Derive the NEAR implicit account from a TEST recovery phrase the way Hermit does on the phone, then read it on mainnet.

    python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
    .venv/bin/python near/near-account.py                      # the public test phrase "abandon x11 about"
    .venv/bin/python near/near-account.py --account near       # read any account (named or implicit), no phrase

Derivation (KeyVault.nearPath in Packages/HermitKit/Sources/HermitWallet/KeyVault.swift):
  BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic")  ->  SLIP-10 ed25519 m/44'/397'/0'
  ->  ed25519 public key  ->  implicit account = the 32-byte public key in lowercase hex (64 chars).
This is what near-seed-phrase / MyNearWallet derive. The expected values are the vector in
Packages/HermitKit/Tests/HermitWalletTests/NearIntentsTests.swift (NearTests.testDerivation), and the script checks them.

Then it reads, over public NEAR RPC (https://free.rpc.fastnear.com, the app's default), view_account and the NEP-141
balances the app tracks (USDC, USDT, wNEAR) via ft_balance_of. Read-only: nothing is signed or sent.

Use test phrases only. Never type a real recovery phrase into a script.
"""
import argparse, base64, hashlib, hmac, json, sys, unicodedata
from decimal import Decimal
from pathlib import Path

import requests
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

RPC = "https://free.rpc.fastnear.com"
TEST_PHRASE = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
# NearTests.testDerivation (checked against near-seed-phrase 0.2.1)
EXPECTED_IMPLICIT = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
EXPECTED_PUBKEY = "ed25519:6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25"
NEAR_PATH = [44, 397, 0]  # all hardened
TOKENS = [("USDC", "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", 6),
          ("USDT", "usdt.tether-token.near", 6), ("wNEAR", "wrap.near", 24)]
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(b: bytes) -> str:
    n, out = int.from_bytes(b, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + out


def check_mnemonic(phrase):
    """BIP-39 checksum against the app's own word list (Resources/bip39-english.txt)."""
    words = (Path(__file__).resolve().parent.parent
             / "Packages/HermitKit/Sources/HermitWallet/Resources/bip39-english.txt").read_text().split()
    parts = phrase.split()
    if len(parts) not in (12, 15, 18, 21, 24) or any(w not in words for w in parts):
        return False
    bits = "".join(f"{words.index(w):011b}" for w in parts)
    cs = len(bits) // 33
    entropy = int(bits[:-cs], 2).to_bytes((len(bits) - cs) // 8, "big")
    return f"{hashlib.sha256(entropy).digest()[0]:08b}"[:cs] == bits[-cs:]


def bip39_seed(phrase, passphrase=""):
    norm = lambda s: unicodedata.normalize("NFKD", s).encode()
    return hashlib.pbkdf2_hmac("sha512", norm(phrase), norm("mnemonic" + passphrase), 2048)


def slip10_ed25519(seed, path):
    i = hmac.new(b"ed25519 seed", seed, hashlib.sha512).digest()
    key, chain = i[:32], i[32:]
    for idx in path:
        i = hmac.new(chain, b"\0" + key + (idx | 0x80000000).to_bytes(4, "big"), hashlib.sha512).digest()
        key, chain = i[:32], i[32:]
    return key


def rpc(method, params):
    r = requests.post(RPC, json={"jsonrpc": "2.0", "id": "hermit", "method": method, "params": params}, timeout=30)
    r.raise_for_status()
    j = r.json()
    if j.get("error"):
        cause = (j["error"].get("cause") or {}).get("name") or j["error"].get("name")
        raise LookupError(cause or json.dumps(j["error"]))
    return j["result"]


def view(contract, method, args):
    r = rpc("query", {"request_type": "call_function", "finality": "final", "account_id": contract, "method_name": method,
                      "args_base64": base64.b64encode(json.dumps(args).encode()).decode()})
    return json.loads(bytes(r["result"]) or b"null")


def fmt(units, decimals):
    return f"{Decimal(units) / (Decimal(10) ** decimals):f}".rstrip("0").rstrip(".") or "0"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phrase", default=TEST_PHRASE, help="a TEST phrase (default: the public 'abandon ... about')")
    ap.add_argument("--account", help="skip derivation and read this account instead")
    a = ap.parse_args()

    bad = 0
    if a.account:
        account = a.account
    else:
        print("Derivation (on the phone this runs inside KeyVault after Face ID; here from a public test phrase)")
        print(f"  phrase             {'the public BIP-39 test phrase abandon x11 about' if a.phrase == TEST_PHRASE else '(your test phrase)'}")
        ok = check_mnemonic(a.phrase)
        bad += not ok
        print(f"  [{'PASS' if ok else 'FAIL'}] BIP-39 checksum (app word list)")
        seed = slip10_ed25519(bip39_seed(a.phrase), NEAR_PATH)
        pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        account, pubkey = pub.hex(), "ed25519:" + b58encode(pub)
        print(f"  path               m/44'/397'/0' (SLIP-10 ed25519)")
        print(f"  public key         {pubkey}")
        print(f"  implicit account   {account}")
        if a.phrase == TEST_PHRASE:
            for name, got, want in [("public key", pubkey, EXPECTED_PUBKEY), ("implicit account", account, EXPECTED_IMPLICIT)]:
                bad += got != want
                print(f"  [{'PASS' if got == want else 'FAIL'}] {name} matches the Swift test vector (NearTests.testDerivation)")

    print(f"\nNEAR mainnet, {RPC} (read-only)")
    try:
        acc = rpc("query", {"request_type": "view_account", "finality": "final", "account_id": account})
        reserved = int(acc.get("storage_usage", 0)) * 10 ** 19
        print(f"  account            {account}")
        print(f"  NEAR balance       {fmt(acc['amount'], 24)} NEAR (storage reserve {fmt(reserved, 24)}, locked {fmt(acc.get('locked', 0), 24)})")
        print(f"  block height       {acc.get('block_height')}")
    except LookupError as e:
        if str(e) != "UNKNOWN_ACCOUNT":
            raise
        print(f"  account            {account}")
        print("  NEAR balance       0 (UNKNOWN_ACCOUNT: an implicit account exists on chain only after it first receives NEAR;")
        print("                     the app shows it as 'not active yet')")
    for sym, contract, dec in TOKENS:
        try:
            bal = view(contract, "ft_balance_of", {"account_id": account})
            print(f"  {sym:<6} (NEP-141)   {fmt(int(bal or 0), dec)}  [{contract}]")
        except LookupError as e:
            print(f"  {sym:<6} (NEP-141)   n/a ({e})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
