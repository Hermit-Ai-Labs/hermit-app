# Hermit Guard

One NEAR smart contract shared by everyone. You open a **vault** in it and put money in. Inside the vault you make **pockets**:
small budgets with rules. An app, a bot or an AI agent gets a pocket's key and can spend only what that pocket allows.
The key can't withdraw, can't change the rules and can't touch the rest of the vault.

Live on NEAR mainnet as `hermit-guard.near`. `DEPLOYMENTS.md` has the address, the code hash and the real-money test; `SECURITY.md` says what each guarantee rests on.

## How it works

* **Vault**: one per NEAR account (the *owner*). Holds balances of native NEAR and of NEP-141 tokens from a fixed list
  (set at deploy time, never changes). Opening it costs a fixed storage deposit of 0.5 NEAR, paid up front and refunded when you
  close the vault. Limits per vault: 8 pockets, 20 standing orders, 10 pending requests, the last 50 receipts.
* **Pocket**: a name, one token, a cap per payment, a cap per day, an optional list of allowed recipients (empty = anyone), an
  optional expiry, a pause switch. Caps are in units of the pocket's token. The contract does not know prices.
* **Pocket key**: a normal NEAR *function-call access key* that you add to **your own account**, limited to this contract and the
  methods `spend` and `request`. When it signs, the contract sees your account as the caller and the key as the signer, and finds
  the pocket that key belongs to.
* **Spend**: the contract pays only if the vault is not frozen, the pocket is not paused or expired, the token and recipient match,
  the amount is within the per-payment cap, today's total stays within the daily cap, and the vault has the money.
* **Daily cap**: a fixed 24 hour window that starts at the first spend after the previous window ended. Right at a window edge
  a pocket can therefore spend one full cap at the end of one window and one at the start of the next.
* **Request**: for something over the caps the key calls `request`. Nothing is paid; the owner sees it and can `approve` (pays,
  even over the caps) or `reject`. A request expires after 7 days.
* **Standing order**: "pay X to Y every N seconds" (N at least 3600), optionally for a fixed number of runs. Anyone may call
  `execute_order`; the contract pays only if it is due and the pocket's normal rules pass. If it was missed it pays once and
  moves to the next time after now: no catch-up bursts. `keeper.py` is a small script that triggers due orders.
* **Owner methods** need exactly 1 yoctoNEAR attached. A function-call key cannot attach any deposit, so a pocket key can never
  call them, even if someone gave it the wrong method list.
* **Freeze** stops spending, approvals and orders. **Withdraw always works**, also when frozen, and only pays your own account.
* If a payout fails (for example the recipient is not registered with the token) the money, the pocket's daily total and the
  order's schedule are put back and the receipt is marked failed.
* **Tokens must be registered.** USDC and USDT only send to accounts that registered storage with them (0.00125 NEAR each). The guard contract
  itself is registered at deploy time (`guard.py deploy` does it). **A recipient must be registered with the token to be paid in it**; otherwise the payment
  fails, the money goes back to the vault and the receipt shows it failed. The owner must be registered to withdraw a token.
* Calls that pay out need gas: attach at least 125 TGas (the tools attach 150).
* There is no admin, no upgrade method and no fee. Events are logged as NEP-297 `EVENT_JSON` (standard `hermit-guard`).

## Files

| | |
|---|---|
| `src/lib.rs` | the contract (about 1000 lines) |
| `src/tests.rs` | unit tests |
| `sandbox-tests/` | end-to-end tests against a local NEAR sandbox with real keys |
| `test-ft/` | a minimal NEP-141 token, only for tests |
| `build.sh` | builds `dist/guard.wasm` |
| `keeper.py` | runs due standing orders (cron friendly) |
| `../../near/guard.py` | command line: view, spend, request, owner commands, deploy |
| `../../near/guard-demo.py` | read-only judge script for the testnet deployment |
| `DEPLOYMENTS.md`, `SECURITY.md` | what is deployed, and what is and isn't proven |

## Build and test

Needs Rust from rustup (the folder pins 1.86.0 and adds the wasm target by itself), and [binaryen](https://github.com/WebAssembly/binaryen)
`wasm-opt` version 119. Plain `cargo build` output is rejected by NEAR (`PrepareError: Deserialization`); `build.sh` fixes the
module with wasm-opt and checks it.

```
cd contracts/guard
cargo test --lib                       # unit tests (40)
./build.sh dist                        # dist/guard.wasm and dist/test_ft.wasm
cd sandbox-tests
GUARD_WASM=$PWD/../dist/guard.wasm FT_WASM=$PWD/../dist/test_ft.wasm cargo test -- --nocapture   # 12 end-to-end tests, downloads the sandbox binary
```

## Use it

Read the live mainnet contract with no key: `.venv/bin/python near/guard.py --network mainnet view info`. The rest below runs against testnet.

```
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/guard-demo.py                    # see the live deployment and the recorded transactions
.venv/bin/python near/guard.py --selftest              # check the transaction encoder offline
.venv/bin/python near/guard.py --key-file owner.json open --near 2
.venv/bin/python near/guard.py --key-file owner.json create-pocket --name coffee --per-payment 0.5 --daily 1 --recipient shop.testnet --key-out coffee-key.json
.venv/bin/python near/guard.py --key-file coffee-key.json spend --amount 0.3 --to shop.testnet --reason latte
```

Deploying: see `DEPLOYMENTS.md`. Mainnet needs `--network mainnet --contract <id>` on every command; there is no default.
