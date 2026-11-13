# How Hermit uses NEAR

Six parts of Hermit run on NEAR: NEAR Intents moves money between chains, Private Cloud runs on NEAR AI Cloud, every
wallet has a NEAR account that can stake with a validator, and three contracts of ours run on mainnet: Hermit Black Box
(`hermit-blackbox.near`, the model registry and flight recorder), Hermit AI insurance (`hermit-insurance.near`) and
Hermit Guard (`hermit-guard.near`, budgets). Code paths below are under
`Packages/HermitKit/Sources/`. To try each part yourself, see [VERIFY.md](VERIFY.md).

## NEAR Intents (1Click)

The wallet holds keys for the EVM chains, Solana and NEAR. Through 1Click it can also deliver to Bitcoin and to a
Hyperliquid account.

- Try a quote, the assistant's `get_quote` and the Swap screen all ask `POST /v0/quote` for dry quotes. A dry quote
  has no deposit address, so nothing can be sent. When you tap Review, Hermit asks again for a live quote with a
  one-time deposit address. Slippage is 1%, and refunds go to your own address on the sending chain
  (`HermitWallet/NearIntents.swift`).
- The Swap screen asks 1Click and Relay at the same time and takes whichever pays out more. The review names the
  route. An Intents swap is one plain transfer from your wallet to the deposit address, through the approval sheet.
  Then Hermit calls `POST /v0/deposit/submit` and polls `GET /v0/status` (`HermitUI/Pages/Wallets/SwapSheet.swift`,
  `HermitWallet/IntentsSwap.swift`).
- In chat, `prepare_swap` gets a quote, refuses a swap that would lose more than 10% of its value, runs the spending
  policy as the assistant, and opens the same Swap review, filled in (`HermitWallet/WalletTools.swift`).
- Add funds takes money from any chain. You pick what you'll send (BTC, ETH, SOL, USDT on Tron and more) and what it
  should arrive as: NEAR, USDC, ETH or SOL on the network you choose, or USDC in your Hyperliquid account. Hermit gets
  a live `FLEX_INPUT` quote and shows the deposit address as a QR code. You can send from an exchange or any other
  wallet; nothing is signed in Hermit. Refunds go to your own address on the sending chain, or to one you type when
  Hermit has no key there (`HermitUI/Pages/Wallets/AnyChainFund.swift`).
- You get a four-step tracker (deposit, seen, swap, delivered) and each 1Click status in plain words: PENDING_DEPOSIT,
  KNOWN_DEPOSIT_TX, PROCESSING, SUCCESS, INCOMPLETE_DEPOSIT, REFUNDED and FAILED. You also see the refunded amount when
  there is one, and a link to explorer.near-intents.org. Swaps show in Activity too (`IntentsStatus` in
  `HermitWallet/NearIntents.swift`, `HermitUI/Pages/Wallets/IntentsViews.swift`).
- Nobody can cancel a 1Click swap: money sent to a deposit address still swaps. You can hide a waiting swap, but
  Hermit keeps tracking it, so a late deposit still shows in Activity. A finished swap can be removed. Start over on
  Add funds hides the old address the same way. Unused, an address expires.
- The device checks 1Click's ed25519 signature on every quote. The check is a field-for-field port of
  `verifyQuoteSignature` from `@defuse-protocol/one-click-sdk-typescript` 0.1.26, down to JavaScript's spread rules
  and `json-stable-stringify` (`NearIntents.swift`).
- A switch on the Swap screen asks 1Click for a confidential swap (`confidentiality: basic`). It needs a 1Click
  partner key and is greyed out without one.
- The partner key is optional. It comes from `ONECLICK_JWT`, from Wallets, Security, or from a key we bundle into
  TestFlight builds. Without one, 1Click adds 0.2%, and the review shows it as the API fee.

1Click prices native NEAR as the token `nep141:wrap.near`. Hermit shows it as NEAR and hides wNEAR from its pickers,
but the quote JSON, `near/intents-quote.py` and the explorer say wNEAR. Hermit doesn't unwrap anything.

Tests: `Tests/HermitWalletTests/NearIntentsTests.swift`, with real dry quotes and the token list recorded on
2026-11-08 in `Fixtures/`. Script: `near/intents-quote.py`.

## A NEAR account in every wallet

Each wallet derives a NEAR implicit account from its recovery phrase: SLIP-10 ed25519 at `m/44'/397'/0'`, the path
near-seed-phrase and MyNearWallet use. A wallet made before we added NEAR gets its account after one Face ID check.

Balances (NEAR, plus USDC, USDT and wNEAR as NEP-141 tokens) come from public RPC (FastNEAR), and the available
balance leaves out the storage reserve. Sends are Borsh-serialized transactions signed with CryptoKit's ed25519:
`Transfer` for NEAR and `ft_transfer` with 1 yocto attached for tokens, with `storage_deposit` first when the receiver
isn't registered with the token. Hermit checks its own signature before sending, submits with `send_tx`
(`EXECUTED_OPTIMISTIC`) and reports a failed receipt as a failure. NEAR can also be the sending side of an Intents
swap, and payees in Payments can be NEAR accounts.

Code: `HermitWallet/Near.swift`, `WalletService+Near.swift`, `KeyVault.swift` (`nearPath`),
`HermitUI/Pages/Wallets/NearViews.swift`. Tests: `NearTests` in `NearIntentsTests.swift` check the bytes against
near-api-js 4 and the keys against near-seed-phrase 0.2.1. Script: `near/near-account.py`.

## Staking NEAR

Every NEAR account can stake with a validator from Earn, or from the Stake button on the wallet's NEAR card. Hermit
calls the validator's staking pool contract directly: `deposit_and_stake` with the NEAR attached, `unstake` or
`unstake_all`, then `withdraw_all`. Each one is a function call with 100 Tgas, built like our other NEAR
transactions and approved with Face ID on the same review sheet.

The list of validators is read from the chain when you open it. Hermit asks the RPC for the current validator set and
keeps pools that are validating this epoch and the next, were online at least 95% of this epoch and were made by the
`poolv1.near` factory. It then reads each pool's fee from the pool itself and shows the six biggest that keep 10% of
rewards or less. The rate on each row is an estimate and says so: what validators were paid last epoch over what is
staked, scaled to a year, less the pool's fee. When that can't be worked out, no rate is shown.

Before a stake reaches the review, Hermit checks the pool again: it is still an active validator, staking isn't paused,
its code hash is the factory's and the pool account has no access keys, so nobody can swap the contract. The review
shows the fee, and 0.05 NEAR always stays in your account on top of the fee, so you can pay to unstake later. Unstaked
NEAR waits four epochs before it can be withdrawn. Hermit measures how long an epoch takes from block timestamps and
shows the wait in hours (about 28 on 2026-11-12). Unstaking again restarts that wait for everything already
unstaking, and the review warns you when that would happen.

Your deposits in Earn shows what is staked, unstaking and ready to withdraw, read from each pool's `get_account`.
Hermit finds your pools from the ones this device staked into and from FastNEAR's index, so a restored wallet shows
its stakes too.

In chat there is no separate staking tool, because the on-device models know a fixed tool list. `prepare_deposit`
with NEAR as the asset prepares a stake, `prepare_withdraw` with NEAR withdraws what is ready or starts an unstake, and
`get_positions` and `get_portfolio` include staked NEAR. A stake the assistant prepares runs the spending policy as the
assistant, with the $100 per-move cap and the daily limit, and can only go to a validator on Hermit's list or one you
already stake with.

Code: `HermitWallet/NearStaking.swift`, `HermitUI/Pages/Earn/EarnStaking.swift`,
`HermitUI/Cloud/HermitToolbox+Staking.swift`. Tests: `NearStakingTests.swift` checks the four calls byte for byte
against near-api-js 4.0.4, parses a real `get_account` answer and a real validator set recorded on 2026-11-12, and
covers the reserve, the assistant's cap and the tool routing.

## Budgets (Hermit Guard)

This is the app side of `contracts/guard/`, a separate NEAR contract with its own README and security notes. The app
shows Budgets only when a Guard contract is set in `GuardConfig` (`contractID` is nil until the mainnet one is
deployed, and debug builds can point at the testnet one with the `hermit.guard.contract` launch argument). In Wallets >
Security, under the spending policy, a Budgets card opens a screen for a vault held in that contract: balances with Add
and Withdraw, a Freeze button, pockets, standing orders, requests waiting for approval and the last payments.

A pocket is a budget with a limit per payment, a limit per day, a list of recipients and an expiry. A pocket made with a
key gets a new ed25519 key made on the device, added to your NEAR account as a function-call key that can only call
`spend` and `request` on the contract (0.25 NEAR of gas budget), and shown once so you can hand it to an app or an
agent. Hermit doesn't keep it. That is two transactions signed in one Face ID check: AddKey first, then `create_pocket`.
If `create_pocket` is refused, a DeleteKey signed in the same unlock goes out at once, so no key is left behind.
Removing a pocket runs `remove_pocket`, then deletes its key, and only a key Hermit made is ever deleted (a function-call
key for this contract limited to those two methods), never a full-access key. The assistant doesn't get a pocket and
nothing in chat changes.

Every owner call attaches exactly 1 yoctoNEAR, which a function-call key can't attach, and carries 150 Tgas (200 for a
token deposit, which goes through the token's `ft_transfer_call`). Before a review opens, Hermit reads the vault, checks
the contract id is the configured one and, for money or authority going in, that its code hash is the one it checked.
It also says in plain words what a pocket can pay without asking you, checks the token is registered on both sides before
a token deposit, and looks at the vault afterwards to be sure the tokens weren't handed back.

Code: `HermitWallet/NearGuard.swift` (actions, reviews), `NearGuardService.swift` (reads, signing and sending),
`HermitUI/Pages/Wallets/GuardViews.swift`. Tests: `NearGuardTests.swift` checks AddKey, DeleteKey and every call byte for
byte against near-api-js 4.0.4, checks each call's arguments against `contracts/guard/src/lib.rs`, decodes real testnet
answers recorded on 2026-11-12, and covers the key ordering, the reviews and the hidden-until-configured switch.

## Black Box (hermit-blackbox.near)

The app side of `contracts/blackbox/`, live on mainnet as `hermit-blackbox.near`.

**Model registry.** Settings > Models asks the contract's `check_model` whether the model you run is the one we
published: its id, the SHA-256 of `model.safetensors` and a digest of every pinned file (SHA-256 over one
`path<TAB>size<TAB>sha256<LF>` line per file, sorted by path). It's a second, public source for the hashes the app
already enforces on download. If NEAR can't be reached the row says so; the download check still stands.

**Flight recorder.** Off by default. Settings > Safety > Black box makes an ed25519 key on the device and adds it to your
NEAR account as a function-call key that can only call `record` on `hermit-blackbox.near`, with a 0.05 NEAR gas
allowance (one Face ID). The key is kept in the Keychain, this device only. After that, each move the assistant
prepared and you approved is hashed: SHA-256 over sorted JSON of the review (title, lines, checks, warnings), the result,
the transaction hash, the model, the time and a 16-byte random salt. Only that hash, a short kind (`swap`, `perp_order`)
and the model id go on chain, as an event log; the text behind it stays on the device, up to the last 500. A record
reserves 3 Tgas and burns about 2. Turning it off deletes the key from your NEAR account and from the device.

Code: `HermitWallet/BlackBox.swift`, `HermitUI/Pages/Settings/BlackBoxSettings.swift`, the hook in
`AppModel.approved`. Tests: `BlackBoxTests.swift` (the Swift digest equals `near/blackbox.py`'s, salted fingerprints,
kinds the contract accepts), `contracts/blackbox/src/tests.rs`, `contracts/blackbox/sandbox-tests`.

## AI insurance (hermit-insurance.near)

The app side of `contracts/insurance/`. Settings > Safety > AI insurance buys 30 days of cover for 1 USDC on NEAR: one
`ft_transfer_call` from your NEAR account to the USDC contract with `msg: "cover"`, approved with Face ID. It then turns
on the Black Box recorder too, since a claim needs its records. While covered, File a claim lists your Black Box
records; you pick the move, say what it cost and what went wrong, and the app calls `file_claim` with the record's
fingerprint and the exact text behind it (the contract checks the hash) and 0.05 NEAR for storage. The contract's owner
sees a Claims list in the same place, with the AI reviewer's verdict, and approves or rejects with a reason; approving
pays the claimant in USDC from the pool.

Code: `HermitWallet/AIInsurance.swift`, `HermitUI/Pages/Settings/InsuranceSettings.swift`. Contract tests:
`contracts/insurance/src/tests.rs` (20), `contracts/insurance/sandbox-tests`. Reviewer tools: `near/insurance.py`.

## Private Cloud on NEAR AI Cloud

The chat box has a mode menu: On-device (the default) or Private Cloud. Private Cloud talks to NEAR AI Cloud's
OpenAI-compatible gateway at `https://cloud-api.near.ai/v1`. Hermit lists only models NEAR runs itself in TEEs
(`owned_by: nearai`) that can call tools, and the default is `Qwen/Qwen3.8-27B`.

Before every reply, the device:

1. Makes 32 random bytes (`SecRandomCopyBytes`) and opens one HTTPS connection to the gateway that it watches.
2. Fetches `/v1/attestation/report` on that connection with the nonce and `include_tls_fingerprint=true`, and no API
   key.
3. Checks the gateway and each model candidate: the TDX v4 quote's signature, its certification by Intel's Quoting
   Enclave and the PCK chain up to an embedded copy of Intel's SGX Root CA, with validity dates; debug mode off; the
   nonce in the quote's report data and echoed back; the signing address bound in the report data;
   `SHA-256(app_compose)` equal to MRCONFIGID; the event log replayed to RTMR3; MRTD, RTMR1 and RTMR2 compared with
   the guest OS images NEAR publishes; evidence for the model you asked for,
   with the nonce in the GPU evidence; and the connection's server key equal to the gateway quote's
   `tls_cert_fingerprint`.
4. Sends the GPU evidence to NVIDIA NRAS and checks the token that comes back: an ES384 signature by a key in NVIDIA's
   published set, NVIDIA as the issuer, the time window, and this request's nonce.

If any check fails, nothing is sent. Otherwise the prompt goes out on the same connection, without streaming and with
`x-no-aliasing: true`. After the reply, the device fetches `/v1/signature/{id}`, hashes the exact request and response
bytes itself, recovers the EIP-191 signer and requires it to be the attested model's key. Each reply gets a Verified
sheet with every check, who did it and what wasn't checked. Tools still run on the device, under the same spending
policy as on-device mode.

Private Cloud comes with 30 free messages per device per day. After that, you can paste your own NEAR AI Cloud key in
Settings, Private Cloud. Your key lives in the Keychain on the device and isn't sent until the checks pass.

Code: `HermitCloud/TDXQuote.swift`, `X509Lite.swift`, `Attestation.swift`, `TLSBinding.swift`,
`ResponseSignature.swift`, `NearAICloud.swift`, `NearCloudAgent.swift`, and `HermitUI/Cloud/`. Tests:
`Tests/HermitCloudTests/`, on real reports recorded on 2026-11-08: a wrong nonce, wrong model, swapped signer, edited
compose, edited event log, flipped quote byte, expired certificate, wrong TLS key, missing GPU verdict, forged NRAS
token and forged response signature each fail. Script: `near/verify-attestation.py`.

## What Hermit checks for you

We've bought NEAR through NEAR Intents with our own money in the app, and these checks run on the device every time:

| What | How the device checks it |
| --- | --- |
| The quote came from 1Click, unchanged | The quote's ed25519 signature is checked before anything is prepared (`testSignatureMatchesSDKOnLiveQuotes`), and a quote that fails is refused (`testUnsignedQuotesAreRefused`). The one exception is a route that starts or ends on Bitcoin, whose signatures don't verify with NEAR's own SDK either: you can still approve those after a warning, and the assistant can't prepare them. |
| The swap pays out to you | The recipient is an address derived from your own wallet. The assistant can't point it anywhere else. |
| Your NEAR transactions | Built byte for byte like near-api-js, and Hermit checks its own signature before sending. |
| It's a genuine Intel TDX enclave | The TDX quote and Intel's certificate chain (an embedded copy of Intel's root), debug off, a fresh nonce, the signer bound in the quote, MRCONFIGID equal to the hash of the published compose file, and the event log replayed to RTMR3. |
| It booted a guest OS NEAR publishes | The quote's MRTD (firmware), RTMR1 (kernel) and RTMR2 (kernel command line, which pins the root filesystem, and initramfs) are compared with the values for NEAR's published images, pinned in `HermitCloud/Attestation.swift` (`testGuestOSIsOneNEARPublishes`). Values the app doesn't know show as not checked, so a new NEAR image doesn't lock you out. The script doesn't trust a list: it rebuilds the values from NEAR's download. |
| Its containers are NEAR's | Not on the device. The script checks NEAR's own images and the model's compose files ([below](#is-it-nears-software)). |
| The GPUs are real | NVIDIA NRAS judges the GPU evidence; the device checks the token's signature, issuer, time and nonce. |
| Your prompt goes only to that enclave | The server key must match the quote's fingerprint, and the prompt goes out on that same connection. |
| The answer is the model's, unchanged | An EIP-191 signature over `model:sha256(request):sha256(response)` by the attested model key, checked as the reply lands. A reply that fails is marked as unverified and loses its review buttons, so it can't lead to a money move. |
| The on-device model is the one we published | Every file and every 128 MiB piece must match a SHA-256 hash pinned in `HermitModel/ModelPins.swift`. |

`near/verify-attestation.py` also checks Intel's TCB status and revocations with `dcap-qvl`. Swap progress comes from
1Click's status API, with an explorer link at every step.

### Is it NEAR's software?

A quote proves a genuine TDX machine and pins hashes. It doesn't say whose software those hashes are. NEAR publishes
three things that do, and `near/verify-attestation.py` checks each one for the gateway and for the model enclave:

| What NEAR publishes | What the script does with it |
| --- | --- |
| The guest OS images its enclaves may boot: [nearai/dstack-images](https://github.com/nearai/dstack-images), one `mr_<os_image_hash>.tar.gz` each with the firmware, kernel, initramfs and command line (dstack's own download site lists the same hashes) | Reads the OS image hash from the RTMR3 event log, downloads that tarball, checks its hashes, and recomputes MRTD, RTMR1 and RTMR2 the way [dstack-mr](https://github.com/Dstack-TEE/dstack/tree/HEAD/dstack/dstack-mr) does. They must equal the quote's. The command line carries the root filesystem's hash, so RTMR2 covers the whole OS. |
| GitHub build attestations (Sigstore) for the images it builds, as described in [Image provenance](https://docs.near.ai/cloud/verification/cloud-api/image-provenance) and the [SDK's verification guide](https://github.com/nearai/inference-sdk/blob/main/py/docs/verification-guide.md) | For `nearaidev/cloud-api` (the gateway), `cvm-ingress` (its TLS front), `compose-manager` and `vllm-proxy-rs` (the inference proxy, which holds the model enclave's signing key): fetches the attestation for the exact digest and verifies it with `sigstore` against Sigstore's public root. The signer must be a GitHub Actions run of NEAR's repository for that image (`nearai/cloud-api`, `nearai/cvm-ingress`, `nearai/compose-manager`, `nearai/inference-proxy`), and the signed statement must name that image and digest. The log shows the workflow, branch and commit. |
| The model's compose files: [nearai/cvm-compose-files](https://github.com/nearai/cvm-compose-files). The model enclave's measured compose only starts NEAR's compose manager, which deploys these files and keeps a log of what it deployed | Checks the manager's TDX quote (Intel DCAP, the same measurements as the model's quote, and report data equal to the hash of the log plus our nonce). Then every compose file behind a service the log has up must be a tagged commit of NEAR's repo with the logged SHA-256. |

`--offline` skips everything that needs the network and compares the OS measurements with pinned values instead.
`--sdk` also runs the image check through NEAR's own `nearai-inference-sdk` for the gateway. The SDK pins nothing
itself: its `verify()` leaves the choice of trusted repositories to the caller, so the list above is ours, taken
from NEAR's guide and from what the attestations say.

What still isn't checked, by the app or the script:

- Which model instance the gateway handed your request to. NEAR's TLS binding ends at the gateway.
- Who built the other images: the model engines (`nearaidev/sglang`, `nearaidev/vllm`), the launcher, nginx, the
  OpenTelemetry collector and a few more. The script lists them on `[SKIP]` lines. Most are pinned by digest in files
  anyone can read; a few local images in NEAR's compose files have no digest at all. The script has no build source
  to hold them to, and for the launcher's digest GitHub had no attestation in `nearai/compose-manager` on 2026-11-12.
- That the manager's log matches what runs this minute. It is a signed record of what was deployed.
- RTMR0, the virtual hardware tables. It is replayed from the event log but not recomputed, which would need QEMU's
  ACPI tables for the exact machine.

So the proof now says: a genuine, non-debug TDX machine with genuine NVIDIA GPUs holds the connection's key, booted an
OS image NEAR publishes, and runs the gateway, compose manager and inference proxy that NEAR's public repositories
built. It says which code that is, not that the code is good.
