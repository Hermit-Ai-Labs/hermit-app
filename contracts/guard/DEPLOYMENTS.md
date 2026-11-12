# Hermit Guard: deployments

## Testnet (live, final build)

| | |
|---|---|
| Contract account | `guard.hermit-guard-owner-1794512081.testnet` |
| Wasm | `contracts/guard/dist/guard.wasm`, **255,757 bytes** |
| sha256 | `dd0ea418dfedf4ab9afde4d804202d06abd1d7459f6eb35131148e6eab4b1b64` (equals the on-chain code hash; `near/guard-demo.py` checks it) |
| Allowlist (immutable) | `near`, `ft.hermit-guard-shop-1794512081.testnet` (our own test token, `test-ft/`; it requires registration like USDC/USDT) |
| Built with | rustc 1.86.0 (`rust-toolchain.toml`), `build.sh` = cargo build `--locked` + binaryen v119 `wasm-opt`, near-sdk 5.17.2 |
| Test accounts | owner `hermit-guard-owner-1794512081.testnet`, shop `hermit-guard-shop-1794512081.testnet`, stranger/keeper `other.hermit-guard-shop-1794512081.testnet` |
| Keys | kept outside the repository (mode 600, testnet only, never committed) |

Every transaction below ran on this exact wasm. (An earlier run used a previous build with the 20 TGas callback; it was replaced
after review. The testnet faucet helper rate-limits by IP, so this run's accounts are sub-accounts created with `guard.py create-account`.)

### The recorded run (every row re-checked on chain by `near/guard-demo.py`)

| # | What | Result | Tx |
|---|---|---|---|
| 1 | deploy hermit_guard.wasm + init in one transaction (allowlist: near + test token) | paid | [`6kc5RFbvxx…`](https://testnet.nearblocks.io/txns/6kc5RFbvxx25hDKSpwBfQcmFf6jaQovU8LyF9CKRLY5j) |
| 2 | deploy the test token + init (it requires registration, like USDC/USDT) | paid | [`HREUfioXLi…`](https://testnet.nearblocks.io/txns/HREUfioXLiU81YXjgtDQcR8cBz1woiewoXw4qFatYHdG) |
| 3 | register the guard contract itself with the token (storage_deposit 0.00125 NEAR, as guard.py deploy does) | paid | [`EFeQDrjymo…`](https://testnet.nearblocks.io/txns/EFeQDrjymo1ZuySQZnDJsF5KHCCTAE9wZaWnhNKKzNXG) |
| 4 | register the shop with the token | paid | [`77a4c3ZbsY…`](https://testnet.nearblocks.io/txns/77a4c3ZbsYQrC3ai8o9a8QBfxaoYPAqzzkCmFeHoFxP9) |
| 5 | owner opens a vault with 3 NEAR | paid | [`ES6bimQYS1…`](https://testnet.nearblocks.io/txns/ES6bimQYS17ipBCwKacq2HzNbhWRyiGzoBZKvpnKAUkK) |
| 6 | owner deposits 1000 test tokens (ft_transfer_call from a registered owner) | paid | [`DY64BZ59ac…`](https://testnet.nearblocks.io/txns/DY64BZ59ac2MpiAjN6P75A2yrPJ1GwZarY9RCcb9pCqU) |
| 7 | owner adds a function-call key (spend/request only) to its OWN account | paid | [`CprXWeHA1A…`](https://testnet.nearblocks.io/txns/CprXWeHA1A33U9T3y9qtcQrBkktyvUUZCy5YdjaQLS7o) |
| 8 | owner creates pocket 'coffee' for that key: 0.5 per payment, 1 per day, shop only | paid | [`CB6dfFpU4J…`](https://testnet.nearblocks.io/txns/CB6dfFpU4JnCAcF6WT8rfxCmehcYBEVV4X9eYk5hCGmn) |
| 9 | POCKET KEY spends 0.4 NEAR to the shop | paid | [`Hq8QcxM7QV…`](https://testnet.nearblocks.io/txns/Hq8QcxM7QV3Nq4nCd6T9Ngh5CFo1L8nyAw62xcxQXrZ6) |
| 10 | POCKET KEY tries 0.6 NEAR (over the per-payment cap) | refused | [`7YBgHbwrGu…`](https://testnet.nearblocks.io/txns/7YBgHbwrGuuLUxSBDCLLucWQJ5AKocExbp9PMrdJtkrE) |
| 11 | POCKET KEY tries 0.4 NEAR to a recipient that is not allowed | refused | [`61SkkUNH9D…`](https://testnet.nearblocks.io/txns/61SkkUNH9DWDy5kmU1d6V22TxapzdWsN9LJ95rfjJRK3) |
| 12 | POCKET KEY spends 0.4 NEAR again (0.8 of 1.0 today) | paid | [`DSXWGp7dfa…`](https://testnet.nearblocks.io/txns/DSXWGp7dfaA7ekZKfhBBN7DqEj4eXrWAyRZvd5p4TQwH) |
| 13 | POCKET KEY tries 0.4 NEAR (over the daily cap) | refused | [`8P6M2oabyo…`](https://testnet.nearblocks.io/txns/8P6M2oabyoSjETEj2MSyksHcaGg11msxXPdfKrF9CaFr) |
| 14 | owner adds a deliberately MISCONFIGURED key that lists withdraw | paid | [`3mgu697zTT…`](https://testnet.nearblocks.io/txns/3mgu697zTT4NoSBNq57Yxrafa76BUQwQxLaz4mAKx64B) |
| 15 | that key calls WITHDRAW (a pocket key cannot attach the 1 yocto) | refused | [`CLZuHHyFg6…`](https://testnet.nearblocks.io/txns/CLZuHHyFg6T5vWQVjdf47ghpGxCFrQuoneUbZX1LdbwC) |
| 16 | owner deletes the misconfigured key | paid | [`DHbBno2QNP…`](https://testnet.nearblocks.io/txns/DHbBno2QNPhAtm3XHLnLUZ2GDQMH8m6YchSb4HNEymTE) |
| 17 | owner adds the key of the token pocket | paid | [`BPCajEDwHX…`](https://testnet.nearblocks.io/txns/BPCajEDwHXn6PNifR5XX3AzrbjJtj3JEbbyecVirs8jo) |
| 18 | owner creates pocket 'tokens' (100 per payment, 250 per day) | paid | [`AEwro22oZr…`](https://testnet.nearblocks.io/txns/AEwro22oZrtZYB9QU4on8fYhHiERyspHtJVCEHP3eKm3) |
| 19 | POCKET KEY spends 100 test tokens to the registered shop | paid | [`BATowC9T2p…`](https://testnet.nearblocks.io/txns/BATowC9T2peG2f6ag2xDWaPdYnXSEbuo7RZbCMYSCn6R) |
| 20 | POCKET KEY requests 1.5 NEAR (over its caps): stored, nothing paid | paid | [`4Mc1ekkBtT…`](https://testnet.nearblocks.io/txns/4Mc1ekkBtTmdCedEr4YwQdYmvLCMKJmTugLapQUPQ74E) |
| 21 | OWNER approves the request: 1.5 NEAR paid | paid | [`7cCZ1YNKnE…`](https://testnet.nearblocks.io/txns/7cCZ1YNKnE9zATwFTftoFwryqBD3eNGNEzvPbhbXwHEN) |
| 22 | owner creates pocket 'rent' (no key: for standing orders only) | paid | [`6FcyJ2MxhB…`](https://testnet.nearblocks.io/txns/6FcyJ2MxhBTt5jTCbVL37quzThv4aqnbwLtSBZBbUvi3) |
| 23 | owner creates a standing order (0.2 NEAR, hourly, 2 runs, first one due now) | paid | [`AyBMXynZAw…`](https://testnet.nearblocks.io/txns/AyBMXynZAwVRa5Gbsi6tsnUxUAkXMhPrRVotvkCFesBc) |
| 24 | A STRANGER triggers the due order: paid | paid | [`AnFZp4EKrM…`](https://testnet.nearblocks.io/txns/AnFZp4EKrM2FFRocuiUdXP5VdRShWC1REHXweSDo15Lu) |
| 25 | the stranger triggers it again in the same period | refused | [`7S1Pxk71MS…`](https://testnet.nearblocks.io/txns/7S1Pxk71MSbRW9Qa3CNLqaZ5eY5dV3uUhEgSz1zJEP4o) |
| 26 | owner freezes the vault | paid | [`8gcY1btMNG…`](https://testnet.nearblocks.io/txns/8gcY1btMNG2DYkDbJ1xKZLqL6fpXm9mNBYaUVvrsnjPH) |
| 27 | POCKET KEY spends while frozen | refused | [`3C5wo8wp95…`](https://testnet.nearblocks.io/txns/3C5wo8wp95CKL33VkxRLSjXjdRpxXSQ1BcxcwqANXs5Q) |
| 28 | owner withdraws 0.3 NEAR while frozen (always allowed) | paid | [`2dyPKUvHrx…`](https://testnet.nearblocks.io/txns/2dyPKUvHrxdJ5TcLYKYHjg4ED82sgbTsoi1Lwcuks5pp) |
| 29 | owner unfreezes | paid | [`ACesuR7WBL…`](https://testnet.nearblocks.io/txns/ACesuR7WBLHqAzK6bzmpbU3iCr5jbzRr4B9isCkZvZxF) |
| 30 | POCKET KEY spends 100 test tokens to an unregistered account: transfer fails, money comes back | restored | [`A5w1yEQvsH…`](https://testnet.nearblocks.io/txns/A5w1yEQvsHHdZQo8FHERkNXusuq4nNNrqhU15wYmYgHw) |
| 31 | owner deposits 0.5 NEAR | paid | [`CbpqtUPJDn…`](https://testnet.nearblocks.io/txns/CbpqtUPJDnrYQqRAk74NQEu2n8VBpXryF3HWgE9PjVXE) |
| 32 | owner creates a second order (0.1 NEAR, due now, one run) for the keeper | paid | [`EDxkura45S…`](https://testnet.nearblocks.io/txns/EDxkura45Sbi1xc5YSnKzKyLLpy5tXTTYjA8MeEQC5op) |
| 33 | KEEPER script (keeper.py) runs the due order | paid | [`J26Qr5ykNA…`](https://testnet.nearblocks.io/txns/J26Qr5ykNAS75qfnVBsaQ6mu1Wf5zyjprPE9e2PFTunH) |

Two more attempts are refused by the NEAR runtime before they reach a block, so they have no hash (verbatim RPC answers):
a pocket key calling `withdraw` with 1 yocto: `InvalidAccessKeyError: "DepositWithFunctionCall"`; with no deposit:
`InvalidAccessKeyError: {"MethodNameMismatch": {"method_name": "withdraw"}}`.
`guard-demo.py --live` replays the attacks with a throwaway account (`--fund-from KEYFILE` if the faucet helper is rate limited).

### Why the wasm needs `wasm-opt`
Plain `cargo build` with rustc 1.86 produces `call_indirect` encodings (reference types) that nearcore rejects with
`PrepareError(Deserialization)`; we hit that error in the sandbox. binaryen v119 rewrites the module and the result validates as
plain MVP wasm (`wasm-tools validate --features=mvp`). The sandbox tests and the testnet load the rewritten file.
`build.sh` also removes build-machine paths, so the same source gives the same bytes anywhere (checked across two directories).

### Gas
`CALLBACK_GAS` (the settlement callback `on_payout`) is 40 TGas, FT transfers get 30 TGas, and payout methods demand 120 TGas left
after the call is decoded (so attach at least 125 TGas; `guard.py` and `keeper.py` attach 150). Measured numbers are in SECURITY.md.

## Tokens must be registered (NEP-141 storage)

USDC and USDT refuse to send tokens to an account that never paid for storage there. Two consequences:
1. **The guard contract itself must be registered** with every allowlisted token, or deposits (`ft_transfer_call`) fail. `guard.py deploy`
   does this right after `new`, from the contract account (`guard.py register-tokens` repeats it, and skips tokens already done).
2. **Every recipient must be registered with the token** to be paid in it. If not, the transfer fails and the contract puts the money
   back (receipt marked failed). The owner of a vault also needs to be registered to withdraw a token.

Read-only check done on mainnet RPC on 2026-11-12 (`guard.py --network mainnet view token-bounds --tokens ...`):

| token | `storage_balance_bounds` |
|---|---|
| USDC `17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1` | min 0.00125 NEAR, max 0.00125 NEAR |
| USDT `usdt.tether-token.near` | min 0.00125 NEAR, max 0.00125 NEAR |

So registering the guard costs exactly 0.00125 NEAR per token (0.0025 NEAR for both).

## Mainnet: PREPARED, NOT RUN

Prerequisites: a deployer account `D.near` with a full-access key file `D.json` and about 2.65 NEAR; `dist/guard.wasm` built by
`build.sh` with sha256 `dd0ea418dfedf4ab9afde4d804202d06abd1d7459f6eb35131148e6eab4b1b64`; the python venv from `near/requirements.txt`. Mainnet needs `--network mainnet`
on every command, every write prints what it will send and stops unless you also pass `--yes`. Run each command once WITHOUT
`--yes` to read the summary, then again with it. `--contract` is mandatory on mainnet. Ids: the contract account `G` below,
e.g. `hermit-guard.D.near` (a sub-account of the deployer, created in step 1; if you already own a fresh named account, skip step 1).

```
cd contracts/guard && CARGO=cargo WASM_OPT=wasm-opt ./build.sh dist        # check the printed sha256 equals the one above
G="hermit-guard.D.near"; PY=".venv/bin/python ../../near/guard.py --network mainnet --contract $G"

# 0. read-only checks, no key, no cost
$PY view token-bounds --tokens 17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1,usdt.tether-token.near

# 1. create the contract account and fund it                              pays 2.600 NEAR (+ ~0.0005 gas)
$PY keygen --out ~/.secrets/guard-mainnet.json --account-id $G              # new key for the contract account, mode 600
PUB=$(python3 -c "import json;print(json.load(open('$HOME/.secrets/guard-mainnet.json'))['public_key'])")
$PY --key-file ~/.secrets/D.json --yes create-account --name $G --public-key $PUB --near 2.6

# 2. deploy the wasm and run `new` in ONE transaction, then register with both tokens (same command)
#                                                                       costs ~0.002 gas + 2 x 0.00125 storage_deposit + ~0.0004 gas, all from the contract account
$PY --key-file ~/.secrets/guard-mainnet.json --yes deploy --wasm dist/guard.wasm \
    --tokens near,17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1,usdt.tether-token.near

# 3. checks (no cost)
$PY view info ; $PY view token-bounds            # version 1.0.0, three tokens, guard registered: yes, yes
# `view info` prints the code sha256 on chain: it must equal the sha256 printed by build.sh

# 4. smoke test with a small vault (your own account, 0.5 NEAR deposit + a little), then close it. Only then consider step 5.
$PY --key-file ~/.secrets/D.json --yes open --near 0.1

# 5. OPTIONAL, IRREVERSIBLE: delete the contract account's full-access key. After this nobody can ever upgrade or fix the contract,
#    and nobody can add keys to the account. Do it only after step 4 worked.
$PY --key-file ~/.secrets/guard-mainnet.json --yes delete-key --public-key $PUB
```

NEAR needed (mainnet, final wasm):

| step | what | NEAR |
|---|---|---|
| 1 | transfer to the contract account (covers everything below) | 2.600 |
| 1 | gas of the create-account transaction, paid by the deployer | ~0.0005 |
| 2 | storage locked by the contract (257,754 bytes: code 255,757 + account, key, state; 1e19 yocto per byte) | 2.5775 (inside the 2.600) |
| 2 | gas of deploy + `new` (20.5 TGas measured) | ~0.0020 |
| 2 | registration with USDC and USDT (2 x 0.00125, measured bounds) | 0.0025 |
| 2 | gas of the two registrations (about 2 TGas each) | ~0.0004 |
| 5 | gas of delete-key | ~0.0001 |
| | **Minimum the contract account must hold** | **2.5825** |
| | **Total leaving the deployer** (2.600 + 0.0005) | **about 2.6005 NEAR** |
| 4 | smoke-test vault (refundable on `close-vault`) | 0.5 + 0.1 |

The 0.0175 NEAR left over is the cushion for gas price changes. Vault storage is prepaid by each user (0.5 NEAR, refunded), so the
contract never needs topping up. Numbers measured on testnet for the same wasm (storage 258,008 bytes with one vault, deploy 20.5 TGas,
register 2.06 TGas); mainnet gas prices can differ.

## Redo it on testnet from a fresh checkout
```
cd contracts/guard && CARGO=cargo WASM_OPT=wasm-opt ./build.sh dist
python3 -m venv .venv && .venv/bin/pip install -r ../../near/requirements.txt
G=".venv/bin/python ../../near/guard.py"
$G new-account --name my-guard.testnet --key-out ~/.secrets/my-guard.json         # faucet helper: 10 NEAR (rate limited per IP)
$G --key-file ~/.secrets/my-guard.json deploy --wasm dist/guard.wasm --tokens near   # deploy + init (+ token registration if any)
$G --contract my-guard.testnet view info
```
