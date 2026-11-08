#!/usr/bin/env python3
"""A live, DRY NEAR Intents (1Click) quote, the way Hermit's "Try a quote" asks for one. No key, no funds, nothing moves.

    python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
    .venv/bin/python near/intents-quote.py                                  # 10 USDC on Base -> NEAR
    .venv/bin/python near/intents-quote.py --from ETH:arbitrum --to USDC:solana --amount 0.01
    .venv/bin/python near/intents-quote.py --from NEAR:near --to USDC:hyperliquid --amount 5
    .venv/bin/python near/intents-quote.py --selftest                       # signature code vs the Swift test vectors

What it does, mirroring Packages/HermitKit/Sources/HermitWallet/NearIntents.swift:
  1. GET  https://1click.chaindefuser.com/v0/tokens  and maps SYMBOL:chain to a 1Click asset id
     (native NEAR is quoted as wNEAR, nep141:wrap.near, as in the app).
  2. POST https://1click.chaindefuser.com/v0/quote   with dry: true, EXACT_INPUT, 1% slippage, ORIGIN_CHAIN deposit.
     dry: true prices the route without creating a deposit address, so nothing can be sent (Q-007).
  3. Checks 1Click's ed25519 signature over the quote exactly as @defuse-protocol/one-click-sdk-typescript 0.1.26
     verifyQuoteSignature does (and as QuoteSignature in the Swift code does): base58(sha256(stable JSON)) signed by
     ed25519:reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc.

Recipient and refund addresses default to the public BIP-39 test phrase "abandon ... about" (the same vectors the
Swift tests use). Pass --recipient / --refund-to for your own. Set ONECLICK_JWT for a partner JWT (optional, Q-006);
without it 1Click adds a 0.2% fee, which this prints. Exit code 1 if the quote's signature does not verify.

Known (2026-11-08): quotes with Bitcoin on either side do not verify, with this code, the Swift code, or the official
SDK's verifyQuoteSignature (see NearIntentsTests.testSignatureMatchesSDKOnLiveQuotes). The app shows those as a
"Quote signature not confirmed" warning instead of a pass; this script prints FAIL and exits 1.
"""
import argparse, base64, datetime, hashlib, json, os, sys
from decimal import Decimal
from pathlib import Path

import requests
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

BASE = "https://1click.chaindefuser.com"
MANAGER_KEY = "ed25519:reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc"  # ONE_CLICK_MANAGER_PUB_KEY, SDK 0.1.26

# Hermit's names for chains -> 1Click blockchain codes (IntentsPlace.blockchain in the Swift code).
CHAINS = {"ethereum": "eth", "base": "base", "arbitrum": "arb", "bnb": "bsc", "polygon": "pol", "monad": "monad",
          "robinhood": "hood", "solana": "sol", "near": "near", "bitcoin": "btc", "hyperliquid": "hypercore"}
EVM_CODES = {"eth", "base", "arb", "bsc", "pol", "monad", "hood", "op", "avax", "gnosis", "bera", "scroll", "abs",
             "plasma", "xlayer", "adi"}
# Public test vectors (BIP-39 "abandon x11 about"): EVM m/44'/60'/0'/0/0, Solana m/44'/501'/0'/0', NEAR m/44'/397'/0'.
TEST_EVM = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
TEST_SOL = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
TEST_NEAR = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
TEST_BTC = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"  # BIP-173 example; the app uses it for dry quotes only
HYPERLIQUID_USDC = "1cs_v1:hypercore:hip1:0x6d1e7cde53ba9467b783cb7c530ce054"


def test_address(code):
    if code in EVM_CODES or code == "hypercore":
        return TEST_EVM
    return {"sol": TEST_SOL, "near": TEST_NEAR, "btc": TEST_BTC}.get(code)


# --- base58 (Bitcoin alphabet), no dependency --------------------------------------------------------------
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + out


def b58decode(s: str) -> bytes:
    n = 0
    for c in s:
        n = n * 58 + B58.index(c)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\0" * (len(s) - len(s.lstrip("1"))) + raw


# --- 1Click quote signature (QuoteSignature in NearIntents.swift) -------------------------------------------
REQUEST_KEYS = ["dry", "swapType", "slippageTolerance", "originAsset", "depositType", "destinationAsset", "amount",
                "refundTo", "refundType", "recipient", "recipientType", "deadline"]
REQUEST_TRUTHY = ["quoteWaitingTimeMs", "referral", "virtualChainRecipient", "virtualChainRefundRecipient", "customRecipientMsg"]
QUOTE_KEYS = ["amountIn", "amountInFormatted", "amountInUsd", "minAmountIn", "amountOut", "amountOutFormatted",
              "amountOutUsd", "minAmountOut"]
QUOTE_TRUTHY = ["depositAddress", "depositMemo", "deadline", "timeWhenInactive", "timeEstimate", "refundFee", "withdrawFee"]


def truthy(v):
    return v is not None and v is not False and v != 0 and v != ""


def js_number(n):
    if isinstance(n, bool):
        return "true" if n else "false"
    if isinstance(n, int) or (n == int(n) and abs(n) < 1e21):
        return str(int(n))
    r = repr(n)
    if "e" in r:  # JS writes 1e-7, Python 1e-07
        m, e = r.split("e")
        r = f"{m}e{'-' if e.startswith('-') else '+'}{e.lstrip('+-').lstrip('0') or '0'}"
    return r


def stable_stringify(v):
    """json-stable-stringify: keys sorted by UTF-16 code units, no whitespace, JSON.stringify escaping."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return js_number(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(stable_stringify(x) for x in v) + "]"
    keys = sorted(v, key=lambda k: k.encode("utf-16-be"))
    return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + stable_stringify(v[k]) for k in keys) + "}"


def quote_message(resp):
    req, q = resp["quoteRequest"], resp["quote"]
    o = {k: req[k] for k in REQUEST_KEYS if k in req}
    o.update({k: req[k] for k in REQUEST_TRUTHY if truthy(req.get(k))})
    o.update({k: q[k] for k in QUOTE_KEYS if k in q})
    if req.get("dry") is not True:
        # JS `{...request, ...quote}` where quote.deadline may be undefined: that removes the request's deadline too.
        for k in QUOTE_TRUTHY:
            if truthy(q.get(k)):
                o[k] = q[k]
            else:
                o.pop(k, None)
    o["timestamp"] = resp["timestamp"]
    return stable_stringify(o)


def quote_hash(resp):
    return b58encode(hashlib.sha256(quote_message(resp).encode()).digest())


def verify_quote(resp, public_key=MANAGER_KEY):
    sig = resp.get("signature") or ""
    try:
        key = Ed25519PublicKey.from_public_bytes(b58decode(public_key.removeprefix("ed25519:")))
        key.verify(b58decode(sig.removeprefix("ed25519:")), quote_hash(resp).encode())
        return True
    except (InvalidSignature, ValueError, KeyError):
        return False


# --- the quote ---------------------------------------------------------------------------------------------
def headers():
    h = {"Accept": "application/json"}
    if os.environ.get("ONECLICK_JWT"):
        h["Authorization"] = f"Bearer {os.environ['ONECLICK_JWT']}"
    return h


def parse_place(s):
    sym, _, chain = s.partition(":")
    chain = chain.lower() or "near"
    return sym, CHAINS.get(chain, chain)


def resolve(tokens, sym, code):
    if code == "hypercore" and sym.upper() == "USDC":
        return next(t for t in tokens if t["assetId"] == HYPERLIQUID_USDC)
    if code == "btc" and sym.upper() == "BTC":
        return next(t for t in tokens if t["assetId"] == "nep141:btc.omft.near")
    if code == "near" and sym.upper() == "NEAR":
        return next(t for t in tokens if t["assetId"] == "nep141:wrap.near")
    here = [t for t in tokens if t["blockchain"] == code and t["symbol"].lower() == sym.lower()]
    if not here:
        have = sorted({t["symbol"] for t in tokens if t["blockchain"] == code})
        sys.exit(f"1Click lists no {sym} on '{code}'. There: {', '.join(have) or 'nothing (unknown chain code)'}")
    return min(here, key=lambda t: t.get("contractAddress") is not None)  # native coin first, as in the app


def iso(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def fmt_usd(s):
    return f"${Decimal(s):,.2f}" if s not in (None, "") else "n/a"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", default="USDC:base", help="SYMBOL:chain to sell (default USDC:base)")
    ap.add_argument("--to", dest="dst", default="NEAR:near", help="SYMBOL:chain to buy (default NEAR:near)")
    ap.add_argument("--amount", default="10", help="amount of --from, in whole units (default 10)")
    ap.add_argument("--recipient", help="where the output goes (default: the test phrase's address on that chain)")
    ap.add_argument("--refund-to", help="refund address on the origin chain (default: the test phrase's address)")
    ap.add_argument("--slippage-bps", type=int, default=100)
    ap.add_argument("--json", action="store_true", help="also print the raw 1Click response")
    ap.add_argument("--selftest", action="store_true", help="check the signature code against the Swift test fixtures, offline")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    tokens = requests.get(f"{BASE}/v0/tokens", headers=headers(), timeout=30).json()
    (fs, fc), (ts, tc) = parse_place(a.src), parse_place(a.dst)
    src, dst = resolve(tokens, fs, fc), resolve(tokens, ts, tc)
    amount = int(Decimal(a.amount) * (10 ** src["decimals"]))
    recipient = a.recipient or test_address(tc)
    refund = a.refund_to or test_address(fc)
    if not recipient or not refund:
        sys.exit("No test address for that chain: pass --recipient and --refund-to.")
    body = {"dry": True, "swapType": "EXACT_INPUT", "slippageTolerance": a.slippage_bps,
            "originAsset": src["assetId"], "depositType": "ORIGIN_CHAIN",
            "destinationAsset": dst["assetId"], "amount": str(amount),
            "recipient": recipient, "recipientType": "DESTINATION_CHAIN",
            "refundTo": refund, "refundType": "ORIGIN_CHAIN",
            "deadline": iso(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10))}
    print(f"1Click dry quote: {a.amount} {src['symbol']} on {src['blockchain']} -> {dst['symbol']} on {dst['blockchain']}")
    print(f"  origin asset       {src['assetId']}")
    print(f"  destination asset  {dst['assetId']}")
    print(f"  recipient          {recipient}")
    r = requests.post(f"{BASE}/v0/quote", json=body, headers=headers(), timeout=60)
    resp = r.json()
    if r.status_code >= 300:
        sys.exit(f"1Click answered HTTP {r.status_code}: {resp.get('message', resp)}")
    q, qr = resp["quote"], resp["quoteRequest"]
    fee_bps = sum(f.get("fee", 0) for f in qr.get("appFees") or [])
    cost = None
    if q.get("amountInUsd") and q.get("amountOutUsd"):
        cost = max(Decimal(0), Decimal(q["amountInUsd"]) - Decimal(q["amountOutUsd"]))
    ok = verify_quote(resp)
    print(f"\n  amount in          {q['amountInFormatted']} {src['symbol']}  ({fmt_usd(q.get('amountInUsd'))})")
    print(f"  amount out         {q['amountOutFormatted']} {dst['symbol']}  ({fmt_usd(q.get('amountOutUsd'))})")
    print(f"  minimum out        {Decimal(q['minAmountOut']) / 10 ** dst['decimals']} {dst['symbol']}  ({a.slippage_bps / 100:g}% slippage)")
    print(f"  1Click fee         {fee_bps} bps ({fee_bps / 100:g}%){'' if os.environ.get('ONECLICK_JWT') else ', the no-JWT fee (Q-006)'}")
    print(f"  total cost         {('$' + format(cost, ',.2f')) if cost is not None else 'n/a'} (in minus out, all fees and spread)")
    print(f"  time estimate      {q.get('timeEstimate', '?')} s")
    print(f"  deposit address    {q.get('depositAddress') or 'none (dry quote: nothing can be sent)'}")
    print(f"  correlation id     {resp.get('correlationId')}")
    print(f"  quote hash         {quote_hash(resp)}")
    print(f"  [{'PASS' if ok else 'FAIL'}] 1Click signature by {MANAGER_KEY}")
    if not ok and "btc" in (src["blockchain"], dst["blockchain"]):
        print("  note: Bitcoin routes don't verify with the official SDK either (see the docstring); the app warns.")
    if a.json:
        print(json.dumps(resp, indent=2))
    sys.exit(0 if ok else 1)


def selftest():
    """The same vectors as NearIntentsTests.testSignatureMatchesSDKOnLiveQuotes / testSignatureNonDryAndTampering."""
    f = Path(__file__).resolve().parent.parent / "Packages/HermitKit/Tests/HermitWalletTests/Fixtures"
    load = lambda n: json.loads((f / f"{n}.json").read_text())
    test_key = "ed25519:GmaDrppBC7P5ARKV8g3djiwP89vz1jLK23V2GBjuAEGB"
    cases = [
        ("quote-dry-base-usdc-to-near", "9AHui9mMPXENEx5uqBXB4Nb3LNMKb45hwkicQzqCsXBn", MANAGER_KEY, True),
        ("quote-dry-near-to-hyperliquid", "GHze8Ge5SnCZW47SWubZs1dw3dNjUfZh8CAL5dr8S2SW", MANAGER_KEY, True),
        ("quote-dry-flex-arb-to-base", None, MANAGER_KEY, True),
        ("quote-dry-btc-refund-intents", "4BZr9KC3hBEP9YXadpWmWStNJAfSM1Eir4jCgB5C19pt", MANAGER_KEY, False),  # SDK rejects it too
        ("quote-live-synthetic-signed", "EvzC7XnxVi7Us7JzjB9hRGBCvgRDt1dX2qfJURvJoDH9", test_key, True),
        ("quote-live-synthetic-signed", None, MANAGER_KEY, False),  # not 1Click's key
        ("quote-live-synthetic-nodeadline", "GwJzNNSZ42KebXjBZgjw1WpmAdE4kRDYiht3oHw8oawJ", test_key, True),
    ]
    bad = 0
    for name, h, key, want in cases:
        j = load(name)
        hok = h is None or quote_hash(j) == h
        got = verify_quote(j, key)
        vok = got == want
        bad += not (hok and vok)
        print(f"  [{'PASS' if hok and vok else 'FAIL'}] {name}: hash {'matches Swift' if h and hok else 'MISMATCH' if h else 'n/a'}, "
              f"signature {'valid' if got else 'invalid'} (expected {'valid' if want else 'invalid'}, key {key[8:16]}…)")
    tampered = load("quote-live-synthetic-signed")
    tampered["quote"]["depositAddress"] = "0x000000000000000000000000000000000000dEaD"
    t_ok = not verify_quote(tampered, test_key)
    bad += not t_ok
    print(f"  [{'PASS' if t_ok else 'FAIL'}] swapped deposit address is rejected")
    print(f"\n{len(cases) + 1 - bad} passed, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
