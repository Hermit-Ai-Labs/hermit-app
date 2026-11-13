# Hermit

## What

An agentic wallet for iPhone and Mac, run by a local AI on your device, that makes advanced crypto strategies
anyone's: say "bridge 20 USDC to Arbitrum and put it in Aave" or "long ETH with $50 at 5x", and it prepares every step.
Nothing moves until you approve with Face ID.

## Why

- Today AI in a wallet means sending your balances and plans to someone's server.
- An AI that moves money needs limits you can check, not trust.
- Cross-chain still takes several apps.

## Built

- **Our own models**, on device, offline: [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit).
  0 false "done" claims in 1,801 tests, never asks for a key in 60 of 60 attacks ([results](docs/MODEL-RESULTS.md)).
- **30 money tools** on EVM, Solana, NEAR, Bitcoin and Hyperliquid, routed by NEAR Intents.
- **Private Cloud** on NEAR AI Cloud, used only after the device checks the enclave's proof.
- **3 contracts on NEAR mainnet:** [`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near)
  (model hashes and a fingerprint of every AI move), [`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near)
  (1 USDC buys 30 days of cover against AI mistakes), [`hermit-guard.near`](https://nearblocks.io/address/hermit-guard.near)
  (on-chain budgets for agents).

## Progress

- **39 TestFlight builds in two weeks** (24 iPhone, 15 Mac).
- Real swaps, staking, Black Box records and an insurance purchase on mainnet, from the app ([README](README.md)).
- 298 app tests passing ([log](docs/logs/core-tests-2026-11-13.txt)). Open source, MIT, training data public
  ([hermit-training](https://github.com/Hermit-Ai-Labs/hermit-training)).
- Revenue: none yet. User numbers: not published yet.

Try it: [Mac](https://hermit.my/dmg) · [iPhone TestFlight](https://testflight.apple.com/join/ed9vUh7d) ·
[Mac TestFlight](https://testflight.apple.com/join/P66H5DF8)

## Money

Wallets earn from swap fees (MetaMask's and Phantom's main income) and from selling to businesses (MetaMask
Institutional, Infura, Phantom Connect; Privy and Dynamic charge per active wallet).

- **B2C:** a small swap fee via our NEAR Intents partner key; paid Private Cloud past the free tier.
- **B2B:**
  1. **Hermit SDK:** our AI, tools and approve flow inside an exchange's or fintech's app, per monthly active user.
  2. **Private deployment:** a model trained on a company's own tools, run on device or in an enclave. Setup fee plus license.
  3. **Black Box, insurance and budgets for other AI agents:** proof of what their AI did, cover for mistakes, on-chain caps.

## Team

[Ryan Chi](https://x.com/MrRyanChi) · [Daksh Joshi](https://x.com/dakshbigshit)

## Ask us

How a fee affects trust · how the insurance pool gets priced · why a wallet, not a plugin.

[hermit.my](https://hermit.my) · [Demo](https://x.com/MrRyanChi/status/2121186366537244978) · [Docs](https://docs.hermit.my) · contact@hermit.my
