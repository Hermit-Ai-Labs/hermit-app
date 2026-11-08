# Hermit Private Cloud on NEAR AI Cloud (track: Privacy & Private AI)

Hermit is an iPhone and Mac app: a private AI wallet whose chat runs fully on the device (MLX, Hermit 1.1 based on
Qwen3). Built during NEAR HACKATHON: **Private Cloud** mode. When a question is too big for the phone, Hermit can
send it to an open model on NEAR AI Cloud that runs inside a TEE (Intel TDX CPU enclave plus NVIDIA H200 GPUs in
confidential-computing mode). Before any prompt leaves the phone, the phone fetches the enclave's attestation with a fresh
random nonce and checks it. After the answer arrives, the phone checks the enclave's signature over the exact request
and response bytes. Each reply has a **Verified** sheet that lists every check, who did it, and what was not checked.

On-device stays the default. Private Cloud is opt-in per chat box (mode menu next to the send button).

## How NEAR AI Cloud is used and what is verified

Hermit calls NEAR AI Cloud's OpenAI-compatible gateway (`https://cloud-api.near.ai/v1`) with the user's own key, which
is stored in the iOS Keychain on the device only. Models are discovered from `/v1/models`, keeping the open models NEAR
runs itself in TEEs (`owned_by: nearai`) that support tool calls; the default is `Qwen/Qwen3.8-27B` (same family as the
on-device Hermit 1.1). Before each prompt (evidence is reused for at most 5 minutes inside one chat), the phone
generates 32 random bytes, fetches `/v1/attestation/report?model=…&provider=near&signing_algo=ecdsa&nonce=…` with
`x-no-aliasing: true` and **no API key**, and verifies the gateway report and every model candidate on the device: the
Intel TDX v4 quote's ECDSA signature by its attestation key, that key's certification by Intel's Quoting Enclave, the
QE report's signature by the PCK certificate, the PCK chain up to a byte-identical copy of Intel's SGX Root CA (with
validity dates), debug mode off, the nonce inside the quote's report data (freshness) and echoed back, the signing
address bound in the quote's report data, `SHA-256(app_compose)` equal to MRCONFIGID, the event log replayed to RTMR3,
the model name, and the nonce inside the GPU evidence. The GPU evidence itself is sent to NVIDIA's attestation service
(NRAS) and its overall verdict is shown as a remote check. If any check fails, nothing is sent. Completions are sent
non-streamed with `x-no-aliasing: true` so that the **model enclave** (`signature_kind: provider_tee`) signs
`model:sha256(request bytes):sha256(response bytes)`; the phone fetches `/v1/signature/{id}`, recomputes both hashes
from the bytes it actually sent and received, recovers the EIP-191 signer with libsecp256k1, and requires it to equal
exactly one verified model report's `signing_address`. Tool calls use the same 11 agent tools as the on-device model
(OpenAI `tools` field); tools run on the phone, and money tools (trade, send, swap) only prepare the existing Face ID
approval sheet. Hermit has no server: the conversation is kept in memory on the phone until New chat.

### Checked on the phone vs not

| Check | Where |
| --- | --- |
| Fresh 32-byte nonce (SecRandomCopyBytes), echoed, and inside each quote's report data | Phone |
| TDX quote v4 signature, QE certification, PCK chain to Intel SGX Root CA, cert dates | Phone (CryptoKit) |
| Debug mode off (TD_ATTRIBUTES bit 0) | Phone |
| Signing address bound in report data (gateway and each model candidate) | Phone |
| MRCONFIGID = 01 ‖ SHA-256(app_compose) ‖ 0…, RTMR3 event-log replay | Phone |
| Evidence is for the requested model, nonce inside GPU evidence | Phone |
| NVIDIA GPU attestation verdict | NVIDIA NRAS (remote; the NRAS token's signature is not checked on the phone) |
| Response signature over exact bytes, signer = attested model key | Phone (libsecp256k1, keccak) |
| Intel TCB level, advisories, revocation (needs Intel collateral) | **Not on the phone.** `verify-attestation.py` does it with `dcap-qvl` |
| Image provenance of container digests | **Not checked** (compose hash is bound to the quote; who built each image is not) |
| TLS connection bound to the gateway quote | **Not checked**: iOS URLSession doesn't expose the peer SPKI per request |
| Gateway-to-model chain for the same request | Not provable today (NEAR docs: a matching model signer doesn't prove the same instance) |

## Try it without an iPhone (Linux or macOS, no API key needed)

```sh
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/verify-attestation.py            # fresh nonce, live report, all checks, exit 1 on failure
.venv/bin/python near/verify-attestation.py --sdk      # also cross-check with NEAR's nearai-inference-sdk verify(model)
NEARAI_API_KEY=… .venv/bin/python near/verify-attestation.py   # plus one completion and its signature check
```

Do: run the first command. See: about 22 `[PASS]` lines for the gateway and the model enclave, including
`Intel DCAP quote verification (dcap-qvl) (TCB UpToDate)` and `NVIDIA NRAS GPU verdict`, then `0 failed`.

Offline, against the recorded reports the Swift unit tests use:

```sh
F=Packages/HermitKit/Tests/HermitCloudTests/Fixtures
.venv/bin/python near/verify-attestation.py --report $F/qwen-report.json --nonce "$(cat $F/qwen-report.nonce)" --offline
```

The script parses the quote with the same byte offsets as the Swift code and checks that its values match `dcap-qvl`'s.

## In the app

- Do: chat box, tap the model name, pick **Private Cloud**. See: the home card checks NEAR AI's enclave live ("Enclave
  verified, no key needed for that").
- Do: Settings, Private Cloud. See: key field (links to cloud.near.ai and the NEAR Builders $10 credit), model picker
  from `/v1/models`, and **Enclave check** with every check listed. Works without a key.
- Do: without a key, send a message. See: it isn't sent; the reply says why and carries a Verified sheet for the enclave.
- Do: with a key, ask something. See: the answer, then a "Verified in a TEE" chip; tap it for the full list.

## Code

- `Packages/HermitKit/Sources/HermitCloud/`: `TDXQuote.swift` (quote parser and DCAP signature chain), `X509Lite.swift`
  (DER, PCK chain, embedded Intel root), `Attestation.swift` (report checks), `ResponseSignature.swift` (EIP-191 and
  Ed25519), `NearAICloud.swift` (API client, NRAS, preflight), `NearCloudAgent.swift` (agent, tool loop, proof).
- `Packages/HermitKit/Sources/HermitUI/Cloud/`: mode menu, home card, Verified sheet, Settings, on-phone tool runner.
- `Packages/HermitKit/Tests/HermitCloudTests/`: recorded real reports (fetched 2026-11-08, no key) with their nonces;
  tests that every check passes on them and that a wrong nonce, wrong model, swapped signer, edited compose, edited
  event log, flipped quote bit, expired certificates and a forged response signature are each caught.
- Prior work (before the hackathon window): the app itself, on-device chat, wallets. The hackathon work is on the
  `near-hackathon` branch.
