# The NEAR scripts

Hermit is an iPhone and Mac app, so we wrote these scripts to let you check its NEAR code without it. Each one does
what the app does, step by step, against the live services. They need Python 3.10 or later on a Mac or Linux machine (3.12 for
`--sdk`), and no keys or funds.

| Script | What it does | A clean run ends with |
| --- | --- | --- |
| `intents-quote.py` | Asks 1Click for a dry quote (10 USDC on Base to NEAR by default) and checks its signature the way `NearIntents.swift` does. `--selftest` checks the same code against the Swift fixtures. | `[PASS] 1Click signature by ed25519:reYaWhvw...`, or `8 passed, 0 failed` with `--selftest` |
| `near-account.py` | Derives the NEAR account from a public test phrase at `m/44'/397'/0'`, as `KeyVault.swift` does, compares it with the Swift test vector, and reads its balances. `--account <id>` reads any account. | Three `[PASS]` lines, then the balances |
| `verify-attestation.py` | Fetches NEAR AI Cloud's attestation with a fresh nonce and checks it as `HermitCloud/` does, plus Intel's TCB status with `dcap-qvl`. Then it checks the enclave runs what NEAR publishes: the guest OS measurements rebuilt from NEAR's image, NEAR's containers against their GitHub build attestations, and the model's compose files against NEAR's public repo ([details](../docs/NEAR.md#is-it-nears-software)). With `NEARAI_API_KEY` it also sends one completion and checks the enclave's signature. | `44 passed, 0 failed, 4 skipped` |
| `attack-demo.py` | Replays prompt-injection and overspending attacks against a Python mirror of the app's guard and spending policy, with the Swift tests' vectors. No installs, no network. | `8 attacks blocked, 3 legitimate actions allowed` |

```sh
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py
.venv/bin/python near/near-account.py
.venv/bin/python near/verify-attestation.py
python3 near/attack-demo.py
```

Run them from the repository root. Every option, with what you should see, is in
[docs/VERIFY.md](../docs/VERIFY.md#the-near-code-with-python). What the device checks itself, and what it leaves to
others, is in [docs/NEAR.md](../docs/NEAR.md#what-hermit-checks-for-you). Recorded runs from 2026-11-08 and 2026-11-12
are in [docs/logs](../docs/logs).
