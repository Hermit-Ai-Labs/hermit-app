# Check Hermit yourself

The Python scripts take a few minutes and need no app. The Swift tests need a Mac with Xcode, and the app needs a
download. Prices, amounts and balances move, so your numbers will differ from ours.

## The NEAR code, with Python

On a Mac or Linux machine with Python 3.10 or later (3.12 for steps 7 and 8). Check `python3 --version` first. If it's older, run
`brew install python@3.12` and type `python3.12` where it says `python3` below. Steps 1 to 7 and 9 need no keys and no
funds. We ran steps 1 to 4 in a fresh clone on 2026-11-11 and steps 5, 6, 7 and 9 on 2026-11-12, on Linux with Python
3.12, and got what the See column says.

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
```

| # | Do | See |
| --- | --- | --- |
| 1 | `.venv/bin/python near/intents-quote.py` | A live dry 1Click quote for 10 USDC on Base to wNEAR: amount out, minimum out, `1Click fee 20 bps`, a time estimate, `deposit address none (dry quote: nothing can be sent)` and `[PASS] 1Click signature by ed25519:reYaWhvw...`. Exit code 0. If solvers aren't quoting that route at the moment, the script says so and quotes NEAR to USDC on Base instead, then USDC from Base to Arbitrum; the last line is the same `[PASS]`. |
| 2 | `.venv/bin/python near/intents-quote.py --selftest` | Eight `[PASS]` lines, then `8 passed, 0 failed`. The signature code gets the same hashes as the Swift tests and rejects a quote whose deposit address was swapped. |
| 3 | `.venv/bin/python near/intents-quote.py --from ETH:arbitrum --to BTC:bitcoin --amount 0.01` | `[FAIL] 1Click signature`, a note, and exit code 1. Quotes that pay out on Bitcoin don't verify with the official SDK's algorithm either, so the app only lets you approve those yourself, after a warning ([why](NEAR.md#what-hermit-checks-for-you)). |
| 4 | `.venv/bin/python near/near-account.py` | From the public test phrase (`abandon` eleven times, then `about`): path `m/44'/397'/0'`, public key `ed25519:6j4b6zUa...`, implicit account `5510e2b4...ee412` and three `[PASS]` lines against the Swift test vector. Then that account's NEAR, USDC, USDT and wNEAR balances from mainnet RPC, read-only. |
| 5 | `.venv/bin/python near/verify-attestation.py` | A fresh nonce, then NEAR AI Cloud's live report for `Qwen/Qwen3.8-27B`, one `[PASS]` per check: the Intel TDX quote, Intel DCAP with `TCB UpToDate`, the nonce, the signer, MRCONFIGID, RTMR3, the TLS key, the GPU evidence and NVIDIA's verdict. Then the checks that it is NEAR's software: the guest OS (`dstack-0.5.12` for the gateway, `dstack-nvidia-0.5.12` for the model) with MRTD, RTMR1 and RTMR2 rebuilt from NEAR's download, a `Built from NEAR's repository` line for `cloud-api`, `cvm-ingress`, `compose-manager` and `vllm-proxy-rs`, and the model's compose files matched to tags of `nearai/cvm-compose-files`. The last line is `44 passed, 0 failed, 4 skipped` ([log](logs/verify-attestation-no-key-2026-11-12.txt)). The skips are the answer's signature, which needs a key, and three lists of images whose builder isn't checked. The run downloads two 17 MB images and makes five anonymous GitHub API calls; GitHub allows 60 an hour per address, and past that those lines read `[SKIP]` and say so (set `GITHUB_TOKEN` to avoid it). |
| 6 | `F=Packages/HermitKit/Tests/HermitCloudTests/Fixtures; .venv/bin/python near/verify-attestation.py --report $F/qwen-report.json --nonce "$(cat $F/qwen-report.nonce)" --offline` | The recorded report our Swift tests use, checked offline: `31 passed, 0 failed, 12 skipped` ([log](logs/verify-attestation-offline-2026-11-12.txt)). Offline, the OS measurements are compared with the values pinned in the script, the same ones the app pins, and everything that needs the network is skipped. |
| 7 | `.venv/bin/pip install -r near/requirements-sdk.txt`, then `.venv/bin/python near/verify-attestation.py --sdk` | The same checks plus NEAR's own `nearai-inference-sdk` running `verify(model)` and its image-provenance helper on the gateway's containers: `47 passed, 0 failed, 4 skipped` ([log](logs/verify-attestation-sdk-no-key-2026-11-12.txt)). |
| 8 | `NEARAI_API_KEY=... .venv/bin/python near/verify-attestation.py --sdk` | Also one short completion on the attested connection, and the enclave's signature over it. Our run on 2026-11-08 ended `29 passed, 0 failed, 0 skipped` ([log](logs/verify-attestation-with-key-2026-11-08.txt)). That was before the checks added on 2026-11-12, and we haven't re-run it with a key since: expect step 7's lines with four completion lines in place of the signature skip. A key comes from https://cloud.near.ai, or $10 of credit from https://nearbuilders.org/dashboard. |
| 9 | `python3 near/attack-demo.py` | No installs and no network. A step-by-step log of ten attacks and controls against a Python mirror of the app's guard and spending policy: an injected tool result and an attached file that try to send funds to `0x...dEaD` are `[BLOCKED]`, an address you typed is `[ALLOWED]` to review, and the $100 cap, own-address rule, 10% loss cap and daily limit each block a swap. The last line is `8 attacks blocked, 3 legitimate actions allowed` ([log](logs/attack-demo-2026-11-12.txt)). The Swift tests below are the source of truth ([why](SECURITY-DEMO.md#without-a-mac)). |

More pairs to try: `--from ETH:arbitrum --to USDC:solana --amount 0.01` and `--from NEAR:near --to USDC:hyperliquid
--amount 5` both end in `[PASS]`. `near-account.py --account near` reads any account. The test phrase is public, so
anyone can move that account's money. Never send anything to it.

## The Swift tests

On a Mac with Xcode 26. The script copies HermitCore, HermitWallet and HermitCloud with their tests into a scratch
package and runs `swift test`, so it doesn't build MLX or the UI.

```sh
bash scripts/core-tests.sh
bash scripts/core-tests.sh --filter 'ToolLoopTests|testSpendPolicy|testNeutralize'
```

On our Mac on 2026-11-12 the first one ended with `Executed 260 tests, with 13 tests skipped and 0 failures`
([log](logs/core-tests-2026-11-12.txt)). The
skipped tests need the network (`HERMIT_LIVE=1`, `HERMIT_LIVE_DAPP=1` or `ONECLICK_LIVE=1`) or a Secure Enclave. The
second runs the 29 tests behind the prompt-injection demo and the spending policy; they all passed in that run. The
walkthrough is [SECURITY-DEMO.md](SECURITY-DEMO.md).

Two live checks from the app's own Swift code, both read-only:

```sh
ONECLICK_LIVE=1 bash scripts/core-tests.sh --filter NearIntentsTests/testLiveDryQuote
HERMIT_LIVE=1 bash scripts/core-tests.sh --filter HermitCloudTests/testLiveAttestation
```

`cd Packages/HermitKit && swift test` runs everything, UI snapshots included. It builds MLX, so it's slower.

## The app

Install it from the links in the [README](../README.md#try-it). On a Mac, read Touch ID wherever it says Face ID.

1. Open Hermit, type your name and tap Create a wallet. Wallets shows one wallet with an EVM address, a Solana address
   and a NEAR account (a 64-character hex implicit account, derived on the device).
2. In Wallets, tap Try a quote (it's there while the wallet is empty) and set 10 USDC on Base to NEAR. You get a live
   NEAR Intents quote: what you'd receive, the fee and the time. It's a dry quote, so there's nothing to sign.
3. Tap Add funds, then "From any chain, via NEAR Intents". Pick what you'll send (BTC on Bitcoin, say), an amount and
   what it should arrive as. You get a one-time deposit address with a QR code, "Address valid until" and a tracker.
   This is mainnet, so only send if you mean it. Start over hides the address.
4. Tap the model name next to Send and pick Private Cloud. A toast says "Private Cloud on. The enclave is checked before
   every message", and the Home card checks NEAR AI's enclave live. Without a key it reads "Enclave verified, no key
   needed for that. Chat needs a NEAR AI Cloud key." With one, it names the model "in an enclave this Mac just
   verified" (or "this phone").
5. Ask "swap 20 USDC on Base to NEAR". The step line under your message reads "Getting a NEAR Intents quote for 20 USDC
   to NEAR" or "Preparing the swap for your review", then the Swap review opens, filled in. With an empty wallet it
   says "Only 0 USDC on Base." and Review stays off. In Private Cloud with a key, the reply gets a "Verified in a TEE"
   chip; tap it for every check.
6. Ask "swap 500 USDC on Base to NEAR". Nothing is prepared, and the reply says the assistant can prepare up to $100
   per move.
7. Open Automations, tap "Every minute, tell me the BTC price and my wallet total" and save it. Within about a minute a
   toast says it ran, and a notification comes too (Hermit asks for permission the first time). Each run is its own
   chat.
8. Switch back to On-device, turn on Airplane mode (or turn off Wi-Fi on a Mac) and ask something. It still answers.

The Mac download and the TestFlight builds come with 30 free Private Cloud messages a day. After that, or in a build
you compile yourself, add your own NEAR AI Cloud key in Settings, Private Cloud. Without a key the enclave check in
step 4 still runs, but your message isn't sent, and the reply says why.
