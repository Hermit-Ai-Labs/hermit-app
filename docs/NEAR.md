# How Hermit uses NEAR

Three parts of Hermit run on NEAR: NEAR Intents moves money between chains, every wallet has a NEAR account, and
Private Cloud runs on NEAR AI Cloud. Code paths below are under `Packages/HermitKit/Sources/`. To try each part
yourself, see [VERIFY.md](VERIFY.md).

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
   `SHA-256(app_compose)` equal to MRCONFIGID; the event log replayed to RTMR3; evidence for the model you asked for,
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
| It's a genuine Intel TDX enclave | The TDX quote and Intel's certificate chain (an embedded copy of Intel's root), debug off, a fresh nonce, the signer bound in the quote, MRCONFIGID equal to the hash of the published compose file, and the event log replayed to RTMR3. The device shows that hash; it doesn't compare it to a list of NEAR releases. |
| The GPUs are real | NVIDIA NRAS judges the GPU evidence; the device checks the token's signature, issuer, time and nonce. |
| Your prompt goes only to that enclave | The server key must match the quote's fingerprint, and the prompt goes out on that same connection. |
| The answer is the model's, unchanged | An EIP-191 signature over `model:sha256(request):sha256(response)` by the attested model key, checked as the reply lands. A reply that fails is marked as unverified and loses its review buttons, so it can't lead to a money move. |
| The on-device model is the one we published | Every file and every 128 MiB piece must match a SHA-256 hash pinned in `HermitModel/ModelPins.swift`. |

`near/verify-attestation.py` goes one step further and checks Intel's TCB status and revocations with `dcap-qvl`. Swap
progress comes from 1Click's status API, with an explorer link at every step.

Two things nobody can prove today: that the gateway handed your request to that exact model instance (NEAR's TLS
binding ends at the gateway), and who built the container images (the quote pins their hash, not their origin). So the
proof says a genuine, non-debug TDX machine with genuine NVIDIA GPUs holds the connection's key and runs the compose
file whose hash is in the quote, and the script also checks Intel's TCB status. It doesn't prove whose software that
compose file runs.
