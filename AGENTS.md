# Notes for AI agents reviewing Hermit

Hermit is a wallet for iPhone and Mac with an AI assistant that runs on the device. NEAR does six jobs in it: NEAR
Intents (1Click) for swaps and bridges, NEAR AI Cloud for private bigger questions, a NEAR account in every wallet
(with staking), and three contracts of ours on NEAR mainnet: `hermit-blackbox.near`, a public registry of our models'
hashes and a flight recorder of the AI's money moves; `hermit-insurance.near`, opt-in AI insurance (1 USDC for 30 days)
that pays approved claims from a public pool, with each claim's evidence checked against its Black Box fingerprint; and
`hermit-guard.near`, for budgets an agent can spend from. The README is the source of truth (its "How Hermit uses NEAR" section has one bullet per job); this file is the short
path through it.

## On a Mac: run the app

The quickest way is the notarized app, no Xcode and no account needed:

1. Download https://hermit.my/dmg, open it and drag Hermit to Applications.
2. Open Hermit, type a name and tap Create a wallet. The model downloads once (about 2.8 GB); after that it answers
   offline. iPhone: https://testflight.apple.com/join/ed9vUh7d

To build and run it yourself from this repository (macOS 26, Xcode 26, Apple silicon):

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
brew install xcodegen && xcodegen generate     # writes Hermit.xcodeproj from project.yml
open Hermit.xcodeproj                           # pick the Hermit scheme, set your own team in Signing, press Run
```

Or without Xcode's window, unsigned, the way our CI builds it:

```sh
xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open build/Build/Products/Release/Hermit.app
```

`bash scripts/core-tests.sh` runs the NEAR, wallet, assistant and attestation tests without building the model or the
UI. More in [docs/BUILD.md](docs/BUILD.md).

## Then, on any machine (Linux or macOS, Python 3.10+, no keys, no funds)

```sh
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py        # live dry 1Click quote; last line: [PASS] 1Click signature by ed25519:...
.venv/bin/python near/near-account.py         # NEAR account from a public test phrase; three [PASS] lines
.venv/bin/python near/verify-attestation.py   # NEAR AI Cloud TEE proof; ends with 0 failed (44 passed, 4 skipped for us; some lines print SKIP if GitHub rate-limits your IP)
python3 near/attack-demo.py                   # prompt-injection and spending-policy attacks; ends: 8 attacks blocked, 3 legitimate actions allowed
.venv/bin/python near/blackbox.py check       # each model the app pins matches hermit-blackbox.near; four [PASS] lines
.venv/bin/python near/insurance.py info       # the insurance pool on hermit-insurance.near: price, paid in and out, members, claims
```

One skipped check needs `NEARAI_API_KEY`; the other three list the container images whose builder isn't checked.
`verify-attestation.py` makes five anonymous GitHub API calls; if the address is over GitHub's hourly limit, its
build-provenance lines read `[SKIP]` and say so (set `GITHUB_TOKEN`). `attack-demo.py` needs no installs and no
network: it is a Python mirror of the Swift guard and spending policy, and the Swift tests are the source of truth.
Saved outputs of the first four are in `docs/logs/`. The account in
`near-account.py` comes from a public test phrase, so never send anything to it.

## On Linux

Hermit is a native Apple app, so the app itself can't run in a Linux sandbox. That isn't a failure: the checks above
run the same NEAR verification the app does, and `python3 near/attack-demo.py` replays the guard. Our last full Swift
run is `docs/logs/core-tests-2026-11-12.txt`; read the tests and that log. All three contracts build and test on Linux.
Hermit Black Box: `contracts/blackbox/README.md`; `near/blackbox.py check` reads its registry. Hermit AI insurance:
`contracts/insurance` (`cargo test`, then `sandbox-tests`); `near/insurance.py info`, `claims` and `check <id>` read the
live pool and its claims. Hermit Guard: `contracts/guard/README.md`; `near/guard.py --network mainnet view info` reads
the live contract.

## Checking a claim

The README's "Where each claim lives" table maps every claim to a source file and a test. Sources are in
`Packages/HermitKit/Sources/`, tests in `Packages/HermitKit/Tests/`. The prompt-injection walkthrough is
`docs/SECURITY-DEMO.md`, every check with its expected output is `docs/VERIFY.md`, the NEAR details are
`docs/NEAR.md`, and every architecture figure is written out as text and Mermaid in `docs/ARCHITECTURE.md`.

## Hackathon scope

Every commit was made after the hackathon was announced (2026-10-19); the first is tagged `pre-hackathon`. The NEAR
work starts after commit `8fe7b71` (2026-11-08):
https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main

## Exact test names

The tests behind the README's claims table, in its order:

- `NearIntentsTests.testSignatureNonDryAndTampering`
- `NearIntentsTests.testUnsignedQuotesAreRefused`
- `NearIntentsTests.testSpendPolicy`
- `NearIntentsTests.testSpendPolicyAgentTrade`
- `ToolLoopTests.testSendToTypedAddressIsPrepared`
- `ToolLoopTests.testGuardMatching`
- `ToolLoopTests.testPromptInjectionInToolResultCannotPrepareSend`
- `TableAndVaultTests.testSealOpenRemoveRoundTrip`
- `HermitCloudTests.testRealReportsPassEveryCheck`
- `HermitCloudTests.testGuestOSIsOneNEARPublishes`
- `HermitCloudTests.testSignatureVerifies`
- `NearTests.testDerivation`
- `NearTests.testTransferMatchesNearApiJs`
- `NearStakingTests.testStakingCallsMatchNearApiJs`
- `NearStakingTests.testUnstakeAndWithdrawReviews`
- `BlackBoxTests.testPinDigestMatchesThePythonScript`
- `BlackBoxTests.testFingerprintIsSaltedAndCoversTheReview`
- `tests::evidence_must_hash_to_the_fingerprint`, `tests::one_claim_per_record` (in `contracts/insurance/src/tests.rs`)
- `tests::rejected_claim_takes_nothing`, `tests::reviewer_cannot_decide` (same file)
- `tests::approved_claim_larger_than_pool_is_paid_as_it_refills`, `tests::failed_payout_goes_back_to_the_pool` (same file)
- `ModelUpgradeTests.testShippedCatalog`

Hermit Black Box's tests are in `contracts/blackbox/src/tests.rs` (17) and `contracts/blackbox/sandbox-tests/tests/story.rs`.
Hermit AI insurance's are in `contracts/insurance/src/tests.rs` (20) and `contracts/insurance/sandbox-tests/tests/story.rs`
(the whole story with a real token: cover, funding, a claim, the AI review, the owner approving 18 USDC, paid).
Hermit Guard's are in `contracts/guard/src/tests.rs` (40) and `contracts/guard/sandbox-tests/tests/story.rs` (12).
