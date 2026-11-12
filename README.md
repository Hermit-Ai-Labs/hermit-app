# Hermit

[![checks](https://github.com/Hermit-Ai-Labs/hermit-app/actions/workflows/checks.yml/badge.svg)](https://github.com/Hermit-Ai-Labs/hermit-app/actions/workflows/checks.yml)
[![Download for Mac](https://img.shields.io/badge/download-Mac-4E1F96?logo=apple&logoColor=white)](https://hermit.my/dmg)
[![iPhone on TestFlight](https://img.shields.io/badge/TestFlight-iPhone-4E1F96?logo=apple&logoColor=white)](https://testflight.apple.com/join/ed9vUh7d)
[![Built on NEAR](https://img.shields.io/badge/built%20on-NEAR%20Intents%20%2B%20NEAR%20AI%20Cloud-00EC97?labelColor=111111)](docs/NEAR.md)
[![Hermit 1.3 on Hugging Face](https://img.shields.io/badge/model-Hermit%201.3-FFD21E?logo=huggingface&logoColor=black&labelColor=111111)](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit)
[![License: MIT](https://img.shields.io/badge/license-MIT-4E1F96.svg)](LICENSE)

Hermit is a wallet for iPhone and Mac with an AI assistant that runs on the device. You ask it in plain words to swap,
bridge, trade or pay. It prepares the move, and nothing leaves your wallet until you approve it with Face ID or Touch
ID. We didn't want our balances and plans on somebody's server, so the model lives on your device. When a question
needs a bigger model, Hermit checks a NEAR AI Cloud enclave's proof before it sends a word.

Tracks: Privacy & Private AI, AI Security & Defense, Unstoppable DeFi.

<p align="center">
<img src="docs/img/screens/offline.jpg" width="190" alt="Hermit's home screen on iPhone: your own AI, works offline.">
<img src="docs/img/screens/swap.jpg" width="190" alt="The Swap review: 5 USDT to 1.37 NEAR via NEAR Intents, cost $0.02 including the 0.2% 1Click fee, under a minute.">
<img src="docs/img/screens/approve.jpg" width="190" alt="The approval sheet: every check listed, and nothing moves until you approve with Face ID.">
<img src="docs/img/screens/proof.jpg" width="190" alt="The Private Cloud proof sheet: the NEAR AI Cloud enclave and the reply's signature, each checked on the phone.">
</p>

## Try it

Hermit is a native app for Apple silicon Macs and iPhones, so the app itself won't run on Linux or Windows. Pick
whichever path fits your machine:

| You have | Do this | You'll see |
| --- | --- | --- |
| A Mac (Apple silicon, macOS 26) | Download https://hermit.my/dmg, drag Hermit to Applications, open it | The app, notarized by Apple. No Xcode, no account, no invite code |
| An iPhone (iOS 26) | Join the iPhone beta on TestFlight: https://testflight.apple.com/join/ed9vUh7d | Hermit on your iPhone, installed through Apple's TestFlight |
| A Mac, through TestFlight | Join the Mac beta on TestFlight: https://testflight.apple.com/join/P66H5DF8 | The same Mac app as the download, updated through TestFlight |
| A Mac with Xcode 26 | Build it from source ([docs/BUILD.md](docs/BUILD.md)) and run `bash scripts/core-tests.sh` | `Executed 260 tests, with 13 tests skipped and 0 failures` |
| Any machine, Linux included | Run the four Python checks in [Check it yourself](#check-it-yourself) | The same NEAR checks the app makes, passing live, and the attacks on the assistant, blocked |
| No Mac or iPhone | Watch the demo video (TODO) and open https://hermit.my/gallery | The screens, and real flows we ran on mainnet |

On first launch the model downloads once: about 2.8 GB, or 1.4 GB on smaller iPhones. After that it answers with Wi-Fi
off. It's mainnet, so real swaps move real money, and nothing moves without your approval.

## Things you can ask it

| Type this | You get |
| --- | --- |
| How much USDC on Solana would 0.5 ETH on Arbitrum get me? | A live NEAR Intents quote. Nothing is prepared |
| Swap 20 USDC on Base to NEAR | The Swap review, filled in from a signed NEAR Intents quote |
| Swap 500 USDC on Base to NEAR | A refusal: the assistant can prepare up to $100 per move. You can change that in Wallets, Security |
| Long ETH with $50 at 5x | A Review long ETH button for a Hyperliquid order |
| Pay everyone in USDC on Base (with a spreadsheet attached) | One batch review for every row |
| Every morning at 8, brief me on my portfolio | An automation that runs while the app is open |
| Explain what a perp is in two sentences (Wi-Fi off) | An answer from the model on your device |

There's also spot trading on Solana through Jupiter, Aave deposits, and a browser where web apps see a Hermit wallet.

## How Hermit uses NEAR

- **[NEAR Intents](docs/NEAR.md#near-intents-1click)** quotes every cross-chain swap and bridge: between EVM chains,
  Solana and NEAR, and out to Bitcoin and Hyperliquid. It also funds the wallet from any chain. The device checks each
  quote's 1Click signature and refuses a quote that fails. Between EVM chains Hermit asks Relay too, takes whichever
  pays out more, and the review names the route.
- **[NEAR AI Cloud](docs/NEAR.md#private-cloud-on-near-ai-cloud)** answers the bigger questions in Private Cloud mode.
  The device checks the enclave's Intel TDX and NVIDIA proof before it sends the prompt, and the model's signature on
  every answer.
- **[A NEAR account](docs/NEAR.md#a-near-account-in-every-wallet)** is in every wallet, derived on the device from the
  same recovery phrase as the EVM and Solana accounts.

## How it fits the tracks

| Track | What the track asks for | What Hermit does | Where |
| --- | --- | --- | --- |
| Privacy & Private AI | AI that protects sensitive data: private AI, TEE, NEAR AI Cloud | The model runs on your device. Bigger questions go to NEAR AI Cloud only after the device has checked the enclave itself: the Intel TDX quote, NVIDIA's GPU verdict, a fresh nonce, the TLS key, then the model's signature on the answer. It also checks the enclave booted an OS image NEAR publishes, and the script checks that NEAR's containers were built from NEAR's public repositories | `HermitCloud/`, `near/verify-attestation.py`, `HermitCloudTests` |
| AI Security & Defense | Spending limits, policy engines, sandboxed wallets: give AI money without the keys | The assistant never holds a key, so there's no key to scope or steal: the keys stay sealed by the Secure Enclave, and it can only prepare a move for your review. A policy caps what it can prepare, a guard in code stops injected text from starting a send, and TEE attestation covers the cloud model. `python3 near/attack-demo.py` replays the attacks on any machine and prints the log | `HermitWallet/SpendPolicy.swift`, `HermitCore/AgentTools.swift`, [near/attack-demo.py](near/attack-demo.py) ([log](docs/logs/attack-demo-2026-11-12.txt)), [SECURITY-DEMO.md](docs/SECURITY-DEMO.md) |
| Unstoppable DeFi | Trading that settles across chains through NEAR Intents, no custodian | Ask for a swap or a bridge and NEAR Intents quotes and settles it, from your own keys. One sentence funds a Hyperliquid account from any chain, and the next opens a perp with take profit and stop loss | `HermitWallet/NearIntents.swift`, `IntentsSwap.swift`, `near/intents-quote.py` |

## Check it yourself

On any Mac or Linux machine with Python 3.10 or later. No keys, no funds, a couple of minutes. These scripts are written
apart from the app and make the same checks it does, so you can see the NEAR side and the guard working without a Mac:

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py        # a live dry quote, ends with [PASS] 1Click signature
.venv/bin/python near/near-account.py         # the NEAR account from a public test phrase, three [PASS] lines
.venv/bin/python near/verify-attestation.py   # NEAR AI Cloud's enclave, ends with 0 failed (44 passed, 4 skipped for us)
python3 near/attack-demo.py                   # attacks on the assistant, ends with 8 attacks blocked, 3 legitimate actions allowed
```

The last one is a Python mirror of the app's guard and spending policy, with the same vectors as the Swift tests
([SECURITY-DEMO.md](docs/SECURITY-DEMO.md#without-a-mac)). It needs no installs.

With Xcode 26, `bash scripts/core-tests.sh` runs the app's NEAR, wallet, assistant and attestation tests. Our last run
is in [docs/logs](docs/logs), and [GitHub Actions](https://github.com/Hermit-Ai-Labs/hermit-app/actions/workflows/apple.yml)
runs the whole suite, UI snapshots included, on every push. [docs/VERIFY.md](docs/VERIFY.md) has every step and what
you should see.

## Where each claim lives

| Claim | Code | Test |
| --- | --- | --- |
| A 1Click quote whose signature fails is refused | `HermitWallet/NearIntents.swift`, `IntentsSwap.swift` | `NearIntentsTests.testSignatureNonDryAndTampering`, `testUnsignedQuotesAreRefused` |
| The assistant can prepare up to $100 per move | `HermitWallet/SpendPolicy.swift` | `NearIntentsTests.testSpendPolicy`, `testSpendPolicyAgentTrade` |
| A send only goes to an address you typed | `HermitCore/AgentTools.swift` (`ToolGuard`) | `ToolLoopTests.testSendToTypedAddressIsPrepared`, `testGuardMatching` |
| A prompt injection in a tool result can't start a send | `HermitCore/ToolLoop.swift`, `ToolCalls.swift` | `ToolLoopTests.testPromptInjectionInToolResultCannotPrepareSend` |
| Keys are sealed by the Secure Enclave and open only for a signature | `HermitWallet/KeyVault.swift` | `TableAndVaultTests.testSealOpenRemoveRoundTrip` (needs a Mac with a Secure Enclave) |
| Private Cloud checks the TDX quote, NVIDIA evidence and TLS key before the prompt | `HermitCloud/Attestation.swift`, `TDXQuote.swift`, `TLSBinding.swift` | `HermitCloudTests.testRealReportsPassEveryCheck` and the tamper tests after it |
| The enclave booted an OS image NEAR publishes, and NEAR's containers come from NEAR's repositories | `HermitCloud/Attestation.swift` (`knownOSImage`), `near/verify-attestation.py` | `HermitCloudTests.testGuestOSIsOneNEARPublishes`, [the script's log](docs/logs/verify-attestation-no-key-2026-11-12.txt) |
| An answer's review buttons need the attested model's signature | `HermitCloud/ResponseSignature.swift`, `NearCloudAgent.swift` | `HermitCloudTests.testSignatureVerifies` |
| Every wallet has a NEAR account, derived on the device | `HermitWallet/Near.swift` | `NearTests.testDerivation`, `testTransferMatchesNearApiJs` |
| The model is ours and pinned by hash | `HermitModel/ModelCatalog.swift`, `ModelPins.swift` | `ModelUpgradeTests.testShippedCatalog` |

Code is under `Packages/HermitKit/Sources/`, tests under `Packages/HermitKit/Tests/`.

## How it works

<p align="center"><a href="docs/img/system_overview.png"><img src="docs/img/system_overview.png" alt="Hermit system overview: on your iPhone or Mac are the chat, the mode switch, the Hermit 1.3 model, the tool loop with 30 guarded tools, the enclave check, the spending policy, the review with Face ID and the key vault with EVM, Solana and NEAR accounts, and outside it are only NEAR AI Cloud, NEAR Intents 1Click, the chains and venues (NEAR, EVM, Solana, Hyperliquid, Relay and Aave v3, Bitcoin), public data, NVIDIA NRAS and the model download." width="620"></a></p>

By default Hermit 1.3 answers on your device, and your chats stay there. In Private Cloud mode the device checks the
enclave's proof first, then sends your prompt on that same connection. Either way the model can only call tools. It
never holds a key. Anything that moves money goes through the
[spending policy](docs/SECURITY-DEMO.md#the-spending-policy) and a review you approve, and only then do the keys sign.
The rest is in [docs/SECURITY-DEMO.md](docs/SECURITY-DEMO.md), with a prompt-injection attack you can run.

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

We train our own. [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) is our fine-tune of
Qwen3-4B, and [Hermit 1.3 Lite](https://huggingface.co/aiquantgod/Hermit-1.3-Lite-MLX-6bit) brings the same skills to
smaller iPhones on Qwen3-1.7B. They learned from 21,000 examples of Hermit tasks, written and checked against the app's own tools: all 30 tools, multi-step requests
like "bridge 20 USDC to Arbitrum, then put it in Aave", recovering when a quote fails, and saying no to anything
unsafe. Two LoRA passes each, Hermit 1.3 on a rented NVIDIA L40S and Lite on an A6000. Both run on your device with
MLX, and the app checks every byte it downloads against hashes built into it.

On held-out test conversations, run in a real tool loop:

| Check | Qwen3-4B, untouched | Hermit 1.2 | Hermit 1.3 | Hermit 1.3 Lite |
| --- | --- | --- | --- | --- |
| Tools it knows | 12 | 12 | 30 | 30 |
| Whole task right (12-tool set) | 57% | 87% | | |
| Prepares a swap when you ask for one | 0 of 8 | 8 of 8 | | 12 of 12 |
| Says "done" or "prepared" without having done it | 9 times | 0 times | 0 of 1,801 | 8 of 1,843 |
| Never asks for a recovery phrase or a key | | | 60 of 60 | 60 of 60 |
| No money call from injected text | | | 59 of 60 | 60 of 60 |
| Every argument traced to your words or a tool result | | | 99.8% | 100% |
| Exact arguments on the new tools | | | 78 to 87% | 81 to 95% |
| Leaves the tools alone when it should just answer | 154 of 160 | 159 of 160 | 88.2% | 91.5% |

Hermit 1.3's numbers are from its first training pass; the weights in the app have a second pass on top. Every test,
both models side by side: [docs/MODEL-RESULTS.md](docs/MODEL-RESULTS.md).

## Questions we get

**Did this exist before the hackathon?** No. The repository starts on 2026-10-29, after the hackathon was announced
on 2026-10-19, and every commit is in the window. The NEAR work starts after commit `8fe7b71` on 2026-11-08 (details
in [Built at NEAR HACKATHON](#built-at-near-hackathon)).

**Can the AI move my money on its own?** No. The model only calls tools, and the money tools only prepare a move. A
review opens, and nothing signs until you approve it with Face ID, Touch ID or your device passcode. The assistant is
also held to the spending policy: up to $100 per move and $500 a day by default, no swap that loses over 10% of its
value, and swap output only to your own addresses.

**What if someone tricks the AI with a prompt injection?** Text from a web page, a file or a tool result can't start a
send, because a send only goes to an address you typed yourself. The guard checks that in code, not in the model, and
a test runs the attack ([SECURITY-DEMO.md](docs/SECURITY-DEMO.md)). `python3 near/attack-demo.py` replays it on any machine.

**What stops a fake quote?** Every 1Click quote is signed. The device checks the ed25519 signature against 1Click's key
and refuses a quote that fails. Quotes that start or end on Bitcoin don't verify with NEAR's own SDK either, so those
are the one exception: you can approve them after a warning, and the assistant can't prepare them.

**Is the spending limit on chain?** No, it's in the app, and it limits the assistant, not you. You hold your own keys,
so you can always send what you like from the Send and Swap screens.

**How private is Private Cloud?** The device checks NEAR AI Cloud's proof before every reply: a genuine Intel TDX
enclave with debug off, genuine NVIDIA GPUs (through NVIDIA's attestation service), a fresh nonce, and the enclave's
own key on the connection your prompt goes out on. Then it checks the model's signature on the answer. The app also
checks that the enclave booted a guest OS image NEAR publishes. `near/verify-attestation.py` goes further: it rebuilds
those OS measurements from NEAR's download, checks that NEAR's own containers (the gateway, the compose manager and
the inference proxy that signs answers) were built by GitHub Actions from NEAR's public repositories, and that the
model's compose files are tagged files in NEAR's public repo. Not checked by either: who built the other images (the
model engines among them), and which model instance the gateway handed your request to.
[NEAR.md](docs/NEAR.md#what-hermit-checks-for-you) lists every check.

**What leaves my device in on-device mode?** Your chats don't. There's no account, no sign-up and no analytics.

**Do I need a NEAR AI account for Private Cloud?** No. The Mac download and the TestFlight builds come with 30 free
Private Cloud messages a day. After that, or in a build you compile yourself, paste your own NEAR AI Cloud key in
Settings, Private Cloud.

**Who holds the keys?** You do. One 12-word recovery phrase, sealed with a key inside the Secure Enclave on your
device. Nothing syncs to iCloud and nothing reaches our servers. Write the phrase down and you can restore the wallet
anywhere.

**Does Hermit charge a fee?** No.

**Why only Mac and iPhone, and why the 26 releases?** The model runs on Apple silicon with Apple's MLX, and the keys are
sealed by the Secure Enclave. The app is built on the iOS 26 and macOS 26 SDKs.

**Is it mainnet?** Yes. NEAR Intents has no testnet, so every swap is real. The Python checks and the demo quotes are
dry quotes, which can't move anything.

**Can I reproduce the model?** The weights, their hashes and the test results are public on Hugging Face. Our
training data and pipeline aren't published.

**Did you use AI to write this?** Yes. We wrote a lot of the code, tests and docs with AI coding agents (Claude Code),
and we review all of it ourselves.

## What's in this repository

- `App/`: the iPhone and Mac apps (SwiftUI), one codebase.
- `Packages/HermitKit/`: everything else. `HermitCore` (assistant, tool loop, guard), `HermitModel` (on-device model,
  MLX), `HermitWallet` (keys, chains, NEAR Intents, spending policy), `HermitCloud` (NEAR AI Cloud and its proofs),
  `HermitUI` (the screens).
- `near/`: the Python checks above, written apart from the app so you can compare the two.
- `docs/`: [NEAR.md](docs/NEAR.md) (how we use NEAR), [SECURITY-DEMO.md](docs/SECURITY-DEMO.md),
  [VERIFY.md](docs/VERIFY.md), [BUILD.md](docs/BUILD.md), [MODEL-RESULTS.md](docs/MODEL-RESULTS.md) and saved run logs in [docs/logs](docs/logs).
- [AGENTS.md](AGENTS.md): the short path for AI reviewers.

## Built at NEAR HACKATHON

We started this repository on 2026-10-29, ten days after the hackathon was announced on 2026-10-19, so every line
here was written in the hackathon window. We tagged the first commit `pre-hackathon`. That commit brings in the UI of
our own web prototype, made on 2026-10-26 (also after the announcement), as the starting point for the Mac app. The
native SwiftUI apps replaced it the same day.

The wallet, the on-device chat and the other chains (EVM, Solana, Hyperliquid) came first. The NEAR work starts after
commit `8fe7b71` on 2026-11-08: Private Cloud on NEAR AI Cloud, the NEAR account, NEAR Intents and the spending
policy. [This diff](https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main) shows everything since then,
the NEAR work and what we built alongside it.

The app uses swift-secp256k1, CryptoSwift, mlx-swift, mlx-swift-lm and swift-transformers, and the scripts use
requests, cryptography, eth-account and dcap-qvl. No templates. Two things of ours live outside this repository,
both made in the same window: the web prototype above, and the lab where we generate training data and train and test
the models.

## Team

- Ryan Chi: [X](https://x.com/MrRyanChi), [LinkedIn](https://www.linkedin.com/in/mrryanchi/), [ryanchi.com](https://www.ryanchi.com/)
- Daksh Joshi: [X](https://x.com/dakshbigshit), [LinkedIn](https://www.linkedin.com/in/joshidaksh/)

MIT, see [LICENSE](LICENSE). Contact: contact@hermit.my.
