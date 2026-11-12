# Hermit

Hermit is a wallet for iPhone and Mac with an AI assistant that runs on the device. You ask it in plain words to swap,
bridge, trade or pay. It prepares the move, and nothing leaves your wallet until you approve it with Face ID or Touch
ID. We didn't want our balances and plans on somebody's server, so the model lives on your device. When a question
needs a bigger model, Hermit checks a NEAR AI Cloud enclave's proof before it sends a word.

Tracks: Privacy & Private AI, AI Security & Defense, Unstoppable DeFi, Agent Economy.

## Try it

Hermit is a native app for Apple silicon Macs and iPhones, so the app itself won't run on Linux or Windows. Pick
whichever path fits your machine:

| You have | Do this | You'll see |
| --- | --- | --- |
| A Mac (Apple silicon, macOS 26) | Download https://hermit.my/dmg, drag Hermit to Applications, open it | The app, notarized by Apple. No Xcode, no account, no invite code |
| A Mac or an iPhone (iOS 26), via TestFlight | Mac: https://testflight.apple.com/join/P66H5DF8, iPhone: https://testflight.apple.com/join/ed9vUh7d | The same app, installed through Apple's TestFlight |
| A Mac with Xcode 26 | Build it from source, see [docs/BUILD.md](docs/BUILD.md), and run the tests with `bash scripts/core-tests.sh` | `Executed 247 tests, with 13 tests skipped and 0 failures` |
| Any machine, Linux included | Run the three Python checks in [Check it yourself](#check-it-yourself) | The same NEAR checks the app makes, passing live |
| Nothing to install | Watch the demo video (TODO) and open https://hermit.my/gallery | The screens, and real flows we ran on mainnet |

On first launch, the model downloads once: about 2.8 GB, or 1.4 GB on smaller iPhones. After that it runs with Wi-Fi
off. It's mainnet, so real swaps move real money, and nothing moves without your approval.

## Things you can ask it

- "How much USDC on Solana would 0.5 ETH on Arbitrum get me?" gets a NEAR Intents quote and prepares nothing.
- "Swap 20 USDC on Base to NEAR" opens the Swap review, filled in from a NEAR Intents quote.
- "Swap 500 USDC on Base to NEAR" doesn't. The assistant can prepare up to $100 per move.
- "Long ETH with $50 at 5x" gives you a Review long ETH button for a Hyperliquid order.
- Drop in a spreadsheet of addresses and amounts and say "pay everyone in USDC on Base" for one batch review.

Turn off Wi-Fi and it still answers. Automations ("every morning at 8, brief me on the market") run while it's open.
There's also spot on Solana through Jupiter, Aave deposits, and a browser where web apps see a Hermit wallet.

## How we use NEAR

- [NEAR Intents](docs/NEAR.md#near-intents-1click) swaps and bridges across EVM chains, Solana, NEAR, Bitcoin and
  Hyperliquid, and funds the wallet from any chain. The device checks every quote's signature.
- [Private Cloud](docs/NEAR.md#private-cloud-on-near-ai-cloud) sends bigger questions to NEAR AI Cloud, but only after
  the device has checked the enclave's attestation. It checks the enclave's signature on each answer too.
- Every wallet has a [NEAR account](docs/NEAR.md#a-near-account-in-every-wallet), derived on the device.

## Check it yourself

On any Mac or Linux machine with Python 3.10 or later. No keys, no funds, about a minute. These scripts are written
apart from the app and make the same checks it does, so you can see the NEAR side working without a Mac:

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py        # a live dry quote, ends with [PASS] 1Click signature
.venv/bin/python near/near-account.py         # the NEAR account from a public test phrase, three [PASS] lines
.venv/bin/python near/verify-attestation.py   # NEAR AI Cloud's enclave, ends with 23 passed, 0 failed, 1 skipped
```

With Xcode 26, `bash scripts/core-tests.sh` runs the app's non-UI tests. Our last run ended with
`Executed 247 tests, with 13 tests skipped and 0 failures` ([full log](docs/logs/core-tests-2026-11-12.txt)).
[docs/VERIFY.md](docs/VERIFY.md) has every step and what you should see, and [docs/BUILD.md](docs/BUILD.md) shows how
to build the apps.

## Where each claim lives

| Claim | Code | Test |
| --- | --- | --- |
| Every 1Click quote's ed25519 signature is checked on the device | `HermitWallet/NearIntents.swift` | `NearIntentsTests.testSignatureNonDryAndTampering` |
| The assistant can prepare up to $100 per move, never more | `HermitWallet/SpendPolicy.swift` | `NearIntentsTests.testSpendPolicy`, `testSpendPolicyAgentTrade` |
| Money tools only prepare; nothing signs before Face ID | `HermitCore/AgentTools.swift` (`ToolGuard`), `HermitWallet/KeyVault.swift` | `NearIntentsTests.testAgentToolsParseChainsAndPrepareIsGuarded` |
| A prompt injection in a tool result can't start a send | `HermitCore/ToolLoop.swift`, `ToolCalls.swift` | `ToolLoopTests.testPromptInjectionInToolResultCannotPrepareSend` |
| Private Cloud checks the TDX quote, NVIDIA evidence and TLS key before the prompt | `HermitCloud/Attestation.swift`, `TDXQuote.swift`, `TLSBinding.swift` | `HermitCloudTests.testRealReportsPassEveryCheck` and the tamper tests after it |
| Each Private Cloud answer is signed by the attested model key | `HermitCloud/ResponseSignature.swift` | `HermitCloudTests.testSignatureVerifies` |
| Every wallet has a NEAR account, derived on the device | `HermitWallet/Near.swift` | `NearTests.testDerivation`, `testTransferMatchesNearApiJs` |
| The model is ours and pinned by hash | `HermitModel/ModelCatalog.swift`, `ModelPins.swift` | `ModelUpgradeTests.testShippedCatalog` |

Code paths are under `Packages/HermitKit/Sources/`, tests under `Packages/HermitKit/Tests/`.

## How it works

<p align="center"><a href="docs/img/system_overview.png"><img src="docs/img/system_overview.png" alt="Hermit system overview: on your iPhone or Mac are the chat, the mode switch, the Hermit 1.3 model, the tool loop with 30 guarded tools, the enclave check, the spending policy, the review with Face ID and the key vault with EVM, Solana and NEAR accounts, and outside it are only NEAR AI Cloud, NEAR Intents 1Click, the chains and venues (NEAR, EVM, Solana, Hyperliquid, Relay and Aave v3, Bitcoin), public data, NVIDIA NRAS and the model download." width="620"></a></p>

By default the Hermit 1.3 model answers on your device, and your chats stay there. In Private Cloud mode the device
checks the enclave's proof first, then sends your prompt on that same connection. Either way the model can only call
tools. It never holds a key. Anything that moves money goes through the
[spending policy](docs/SECURITY-DEMO.md#the-spending-policy) and a review you approve, and only then do the keys sign.
They're sealed with a Secure Enclave key. There's no account and no analytics. The rest is in
[docs/SECURITY-DEMO.md](docs/SECURITY-DEMO.md), with a prompt-injection attack you can run.

<table>
<tr>
<td width="50%" valign="top"><b>One swap, end to end.</b> The assistant only prepares it, and nothing is signed before your Face ID.<br><br><a href="docs/img/money_move.png"><img src="docs/img/money_move.png" alt="Sequence of one swap of 20 USDC on Base to NEAR: the assistant calls prepare_swap, Hermit gets a dry 1Click quote, checks its ed25519 signature and the spending policy and opens the Swap review, a live quote brings a one-time deposit address and the checks run again, you approve with Face ID, the Secure Enclave unseals the seed, Hermit signs and sends the USDC to the deposit address and submits the hash, and 1Click's solvers deliver wNEAR to your NEAR account while Hermit polls the status." width="400"></a></td>
<td width="50%" valign="top"><b>Private Cloud, proof first.</b> The device checks NEAR AI Cloud's enclave before every reply, and only then sends your prompt.<br><br><a href="docs/img/private_cloud.png"><img src="docs/img/private_cloud.png" alt="Private Cloud in three phases: the device makes a fresh 32-byte nonce, fetches the gateway's and the model's attestation on one watched HTTPS connection without an API key, sends only the GPU evidence to NVIDIA NRAS and checks the TDX quotes, the NVIDIA token and the connection key, then sends the prompt and the key on that same connection and runs tool calls on the device, then fetches the reply's signature and requires the attested model key." width="400"></a></td>
</tr>
<tr>
<td valign="top"><b>The assistant and what stops it</b>, with the prompt-injection test along the bottom.<br><br><a href="docs/img/assistant_loop.png"><img src="docs/img/assistant_loop.png" alt="The assistant's loop on the device: your message and the system prompt go to the Hermit 1.3 model, a tool guard checks every tool call before the toolbox runs it, read tools fetch public data, money tools only prepare and then pass the spending policy and your review with Face ID, tool results are cleaned before the model reads them, and a five-step log shows an injected instruction in a tool result being hidden, the guard refusing the send and no review opening." width="400"></a></td>
<td valign="top"><b>Where the keys live.</b> One recovery phrase gives you an EVM, a Solana and a NEAR account.<br><br><a href="docs/img/keys_accounts.png"><img src="docs/img/keys_accounts.png" alt="A 12-word recovery phrase is sealed with AES-GCM under a key agreed with a Secure Enclave P-256 key, Face ID or Touch ID unseals the seed in memory only while signing, and Hermit derives one key, EVM at m/44'/60'/0'/0/0, Solana at m/44'/501'/0'/0' or NEAR at m/44'/397'/0', signs with it and wipes it." width="400"></a></td>
</tr>
</table>

Tap any figure to open it full size.

## Our models

We train our own models. [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) is our fine-tune of
Qwen3-4B, and [Hermit 1.3 Lite](https://huggingface.co/aiquantgod/Hermit-1.3-Lite-MLX-6bit) brings the same skills to
smaller iPhones on Qwen3-1.7B. They learned from 21,000 examples of real Hermit work: all 30 tools, multi-step requests
like "bridge 20 USDC to Arbitrum, then put it in Aave", recovering when a quote fails, and saying no to anything unsafe.
Two passes each on rented GPUs (an L40S and an A6000). Both run on your device with MLX, and the app checks every byte
it downloads against hashes built into it.

## What's in this repository

- `App/`: the iPhone and Mac apps (SwiftUI), one codebase.
- `Packages/HermitKit/`: everything else. `HermitCore` (assistant, tool loop, guard), `HermitModel` (on-device model,
  MLX), `HermitWallet` (keys, chains, NEAR Intents, spending policy), `HermitCloud` (NEAR AI Cloud and its proofs),
  `HermitUI` (the screens).
- `near/`: the Python checks above, written apart from the app so you can compare the two.
- `docs/`: [NEAR.md](docs/NEAR.md) (how we use NEAR), [SECURITY-DEMO.md](docs/SECURITY-DEMO.md),
  [VERIFY.md](docs/VERIFY.md), [BUILD.md](docs/BUILD.md) and saved run logs in [docs/logs](docs/logs).

## Built at NEAR HACKATHON

We started this repository on 2026-10-29, ten days after the hackathon was announced on 2026-10-19, so every line
here was written in the hackathon window. We tagged the first commit `pre-hackathon`. The wallet, the on-device chat and the other chains (EVM, Solana, Hyperliquid) came first. The NEAR
work starts after commit `8fe7b71` on 2026-11-08: Private Cloud on NEAR AI Cloud, the NEAR account, NEAR Intents and
the spending policy. [This diff](https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main) shows everything
since then.

The app uses swift-secp256k1, CryptoSwift, mlx-swift, mlx-swift-lm and swift-transformers, and the scripts use
requests, cryptography, eth-account and dcap-qvl. No templates or boilerplate. We wrote a lot of the code, tests and
docs with AI coding agents (Claude Code), and we review all of it ourselves.

MIT, see [LICENSE](LICENSE). Contact: contact@hermit.my. Team: TODO
