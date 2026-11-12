# The NEAR scripts

Hermit is an iPhone and Mac app, so we wrote these scripts to let you check its NEAR code without it. Each one does
what the app does, step by step, against the live services. They need Python 3.10 or later on a Mac or Linux machine (3.12 for
`--sdk`), and no keys or funds.

| Script | What it does | A clean run ends with |
| --- | --- | --- |
| `intents-quote.py` | Asks 1Click for a dry quote (10 USDC on Base to NEAR by default) and checks its signature the way `NearIntents.swift` does. `--selftest` checks the same code against the Swift fixtures. | `[PASS] 1Click signature by ed25519:reYaWhvw...`, or `8 passed, 0 failed` with `--selftest` |
| `near-account.py` | Derives the NEAR account from a public test phrase at `m/44'/397'/0'`, as `KeyVault.swift` does, compares it with the Swift test vector, and reads its balances. `--account <id>` reads any account. | Three `[PASS]` lines, then the balances |
| `verify-attestation.py` | Fetches NEAR AI Cloud's attestation with a fresh nonce and checks it as `HermitCloud/` does, plus Intel's TCB status with `dcap-qvl`. With `NEARAI_API_KEY` it also sends one completion and checks the enclave's signature. | `23 passed, 0 failed, 1 skipped` |

```sh
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py
.venv/bin/python near/near-account.py
.venv/bin/python near/verify-attestation.py
```

Run them from the repository root. Every option, with what you should see, is in
[docs/VERIFY.md](../docs/VERIFY.md#the-near-code-with-python). What the device checks itself, and what it leaves to
others, is in [docs/NEAR.md](../docs/NEAR.md#what-the-device-checks-and-what-it-doesnt). Recorded runs from 2026-11-08
are in [docs/logs](../docs/logs).
