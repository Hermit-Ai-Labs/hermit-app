# Hermit

Hermit is a wallet for iPhone and Mac with an AI assistant that runs on the device. You ask it in plain words to swap,
bridge, trade or pay. It prepares the move, and nothing leaves your wallet until you approve it with Face ID or Touch
ID. We didn't want our balances and plans on somebody's server, so the model lives on your device. When a question
needs a bigger model, Hermit checks a NEAR AI Cloud enclave's proof before it sends a word.

## Try it

- Mac: https://hermit.my/dmg (notarized, Apple silicon, macOS 26)
- Mac TestFlight: https://testflight.apple.com/join/P66H5DF8
- iPhone TestFlight: https://testflight.apple.com/join/ed9vUh7d (iOS 26)
- Demo video: TODO

The model downloads on first launch (about 2.3 GB, 1 GB on smaller iPhones). It's mainnet: real swaps move real money.

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

On a Mac with Python 3.10 or later. No keys, no funds:

```sh
git clone https://github.com/Hermit-Ai-Labs/hermit-app && cd hermit-app
python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
.venv/bin/python near/intents-quote.py        # a live dry quote, ends with [PASS] 1Click signature
.venv/bin/python near/near-account.py         # the NEAR account from a public test phrase, three [PASS] lines
.venv/bin/python near/verify-attestation.py   # NEAR AI Cloud's enclave, ends with 23 passed, 0 failed, 1 skipped
```

With Xcode 26, `bash scripts/core-tests.sh` runs the app's non-UI tests. [docs/VERIFY.md](docs/VERIFY.md) has every
step and what you should see, and [docs/BUILD.md](docs/BUILD.md) shows how to build the apps.

## How it works

<img src="docs/img/system_overview.png" alt="Hermit system overview: on your iPhone or Mac are the chat, the mode switch, the Hermit 1.2 model, the tool loop with 15 guarded tools, the enclave check, the spending policy, the review with Face ID and the key vault with EVM, Solana and NEAR accounts, and outside it are only NEAR AI Cloud, NEAR Intents 1Click, the chains and venues (NEAR, EVM, Solana, Hyperliquid, Relay and Aave v3, Bitcoin), public data, NVIDIA NRAS and the model download." width="880">

By default the Hermit 1.2 model answers on your device, and your chats stay there. In Private Cloud mode the device
checks the enclave's proof first, then sends your prompt on that same connection. Either way the model can only call
tools. It never holds a key. Anything that moves money goes through the
[spending policy](docs/SECURITY-DEMO.md#the-spending-policy) and a review you approve, and only then do the keys sign.
They're sealed with a Secure Enclave key. There's no account and no analytics. The rest is in
[docs/SECURITY-DEMO.md](docs/SECURITY-DEMO.md), with a prompt-injection attack you can run.

One swap from start to finish. The assistant only prepares it, and nothing is signed before your Face ID:

<img src="docs/img/money_move.png" alt="Sequence of one swap of 20 USDC on Base to NEAR: the assistant calls prepare_swap, Hermit gets a dry 1Click quote, checks its ed25519 signature and the spending policy and opens the Swap review, a live quote brings a one-time deposit address and the checks run again, you approve with Face ID, the Secure Enclave unseals the seed, Hermit signs and sends the USDC to the deposit address and submits the hash, and 1Click's solvers deliver wNEAR to your NEAR account while Hermit polls the status." width="880">

Private Cloud. The device checks NEAR AI Cloud's enclave before every reply, and only then sends your prompt:

<img src="docs/img/private_cloud.png" alt="Private Cloud in three phases: the device makes a fresh 32-byte nonce, fetches the gateway's and the model's attestation on one watched HTTPS connection without an API key, sends only the GPU evidence to NVIDIA NRAS and checks the TDX quotes, the NVIDIA token and the connection key, then sends the prompt and the key on that same connection and runs tool calls on the device, then fetches the reply's signature and requires the attested model key." width="880">

The assistant and what stops it, with the prompt-injection test along the bottom:

<img src="docs/img/assistant_loop.png" alt="The assistant's loop on the device: your message and the system prompt go to the Hermit 1.2 model, a tool guard checks every tool call before the toolbox runs it, read tools fetch public data, money tools only prepare and then pass the spending policy and your review with Face ID, tool results are cleaned before the model reads them, and a five-step log shows an injected instruction in a tool result being hidden, the guard refusing the send and no review opening." width="880">

Where the keys live. One recovery phrase gives you an EVM, a Solana and a NEAR account:

<img src="docs/img/keys_accounts.png" alt="A 12-word recovery phrase is sealed with AES-GCM under a key agreed with a Secure Enclave P-256 key, Face ID or Touch ID unseals the seed in memory only while signing, and Hermit derives one key, EVM at m/44'/60'/0'/0/0, Solana at m/44'/501'/0'/0' or NEAR at m/44'/397'/0', signs with it and wipes it." width="880">

## Our models

We train our own. Hermit 1.2 is a LoRA fine-tune of Qwen3-4B-Instruct-2507 on Hermit's tools, trained on one rented
NVIDIA A6000. Hermit 1.3 and 1.3 Lite (Qwen3-1.7B) are training right now on 21,000 examples of real Hermit tasks, on
an A100 80GB and an A6000. They run on your device as MLX 4-bit. Weights: [huggingface.co/aiquantgod](https://huggingface.co/aiquantgod).

## Built at NEAR HACKATHON

We started this repository on 2026-10-29, ten days after the hackathon was announced, and tagged the first commit
`pre-hackathon`. The wallet, the on-device chat and the other chains (EVM, Solana, Hyperliquid) came first. The NEAR
work starts after commit `8fe7b71` on 2026-11-08: Private Cloud on NEAR AI Cloud, the NEAR account, NEAR Intents and
the spending policy. [This diff](https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main) shows everything
since then.

The app uses swift-secp256k1, CryptoSwift, mlx-swift, mlx-swift-lm and swift-transformers, and the scripts use
requests, cryptography, eth-account and dcap-qvl. No templates or boilerplate. We wrote a lot of the code, tests and
docs with AI coding agents (Claude Code), and we review all of it ourselves.

MIT, see [LICENSE](LICENSE). Contact: contact@hermit.my. Team: TODO
