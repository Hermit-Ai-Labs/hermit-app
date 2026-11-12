# Notes for AI agents reviewing Hermit

Hermit is a wallet for iPhone and Mac with an AI assistant that runs on the device. NEAR does three jobs in it: NEAR
Intents (1Click) for swaps and bridges, NEAR AI Cloud for private bigger questions, and a NEAR account in every wallet.
The README is the source of truth; this file is the short path through it.

## Run these first (Linux or macOS, Python 3.10+, no keys, no funds)

```sh
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py        # live dry 1Click quote; last line: [PASS] 1Click signature by ed25519:...
.venv/bin/python near/near-account.py         # NEAR account from a public test phrase; three [PASS] lines
.venv/bin/python near/verify-attestation.py   # NEAR AI Cloud TEE proof; ends with 0 failed (44 passed, 4 skipped for us; some lines print SKIP if GitHub rate-limits your IP)
python3 near/attack-demo.py                   # prompt-injection and spending-policy attacks; ends: 8 attacks blocked, 3 legitimate actions allowed
```

One skipped check needs `NEARAI_API_KEY`; the other three list the container images whose builder isn't checked.
`verify-attestation.py` makes five anonymous GitHub API calls; if the address is over GitHub's hourly limit, its
build-provenance lines read `[SKIP]` and say so (set `GITHUB_TOKEN`). `attack-demo.py` needs no installs and no
network: it is a Python mirror of the Swift guard and spending policy, and the Swift tests are the source of truth.
Saved outputs of all four are in `docs/logs/`. The account in
`near-account.py` comes from a public test phrase, so never send anything to it.

## What needs a Mac

Hermit is a native Apple app, so it can't run in a Linux sandbox. That isn't a failure: a judge with a Mac installs the
notarized build from https://hermit.my/dmg (no Xcode needed), and iPhone users join TestFlight
(https://testflight.apple.com/join/ed9vUh7d). Building from source and the Swift tests need macOS 26 and Xcode 26.
`bash scripts/core-tests.sh` runs the NEAR, wallet, assistant and attestation tests without building the model or the UI. Our last full run is
`docs/logs/core-tests-2026-11-12.txt` (260 tests, 13 skipped, 0 failures; the skipped ones need the network or a
Secure Enclave). On Linux, read the tests and that log.

## Checking a claim

The README's "Where each claim lives" table maps every claim to a source file and a test. Sources are in
`Packages/HermitKit/Sources/`, tests in `Packages/HermitKit/Tests/`. The prompt-injection walkthrough is
`docs/SECURITY-DEMO.md`, every check with its expected output is `docs/VERIFY.md`, and the NEAR details are
`docs/NEAR.md`.

## Hackathon scope

Every commit was made after the hackathon was announced (2026-10-19); the first is tagged `pre-hackathon`. The NEAR
work starts after commit `8fe7b71` (2026-11-08):
https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main
