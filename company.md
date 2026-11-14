# Hermit

Hermit is a crypto wallet for iPhone and Mac with its own AI running on your device. You say what you want, like
"bridge 20 USDC to Arbitrum and put it in Aave" or "long ETH with $50 at 5x", and it lines up every step. Nothing
moves until you approve with Face ID.

## Why

AI in a wallet today means sending your balances and plans to someone else's server. If an AI is going to move your
money, you should be able to check its limits yourself instead of taking them on trust. And going cross-chain still
means juggling several apps.

## What works today

- **Our own model runs offline on the device.** In 1,801 tests,
  [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) never once said a move was done when it
  wasn't, and it never asked for a private key in any of 60 attack attempts ([results](docs/MODEL-RESULTS.md)).
- **30 money tools** across EVM, Solana, NEAR, Bitcoin and Hyperliquid, routed by NEAR Intents.
- **Private Cloud** on NEAR AI Cloud handles bigger questions, and the device checks the enclave's proof before
  sending anything.
- **3 contracts on NEAR mainnet.** [`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near) records
  model hashes and a fingerprint of every AI move.
  [`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near) sells 30 days of cover against AI
  mistakes for 1 USDC. [`hermit-guard.near`](https://nearblocks.io/address/hermit-guard.near) gives agents on-chain
  budgets.

## Progress and traction (as of 2026-11-13)

We shipped 39 TestFlight builds in two weeks (24 iPhone, 15 Mac) and trained and published 4 models, with their hashes
on chain. 298 app tests pass ([log](docs/logs/core-tests-2026-11-13.txt)). Everything is open source under MIT, training
data included ([hermit-training](https://github.com/Hermit-Ai-Labs/hermit-training)).

Usage is early: 6 waitlist sign-ups and 6 public TestFlight testers. The mainnet activity so far (swaps, staking, 2 Black
Box records, 1 insurance member) is our own ([README](README.md)). No revenue yet.

Try it: [Mac](https://hermit.my/dmg) · [iPhone TestFlight](https://testflight.apple.com/join/ed9vUh7d) ·
[Mac TestFlight](https://testflight.apple.com/join/P66H5DF8)

## How we make money

Wallets earn mainly from swap fees, which is most of MetaMask's and Phantom's income, and from selling to businesses.
We plan to do both.

- **Consumers** pay a small swap fee through our NEAR Intents partner key, and pay for Private Cloud past the free tier.
- **Businesses** can put our AI and approval flow inside their exchange or fintech app with the Hermit SDK, priced per
  monthly active user. A company that wants its own model gets one trained on its tools and run on device or in an
  enclave, for a setup fee plus a license. Other AI agents can also use Black Box, insurance and Guard for proof of
  what they did, cover for mistakes and spending caps.

## Team

**[Ryan Chi](https://x.com/MrRyanChi)** ([site](https://www.ryanchi.com/)) co-founded
[insiders.bot](https://x.com/insidersdotbot), a Solana and prediction-market trading bot that peaked at US$360K ARR and
$1M+ in monthly volume. He is co-president of 0xU Club, Hong Kong's largest Web3 student association, and studied at
UPenn (FranklinDAO) and CUHK.

**[Daksh Joshi](https://x.com/dakshbigshit)** ([LinkedIn](https://www.linkedin.com/in/joshidaksh/)) co-founded
insiders.bot with Ryan, and Sigmaboy.ai. He does technical BD at Astralane (low-latency trading infrastructure) and was
CPO at PublicAI. He studied finance and maths at CUHK, where he now guest-lectures Solidity and DeFi in a Business
School master's course.

## Ask us about

How a fee affects trust, how we price the insurance pool, and why we built a wallet rather than a plugin.

[hermit.my](https://hermit.my) · [Demo](https://x.com/MrRyanChi/status/2121186366537244978) · [Docs](https://docs.hermit.my) · contact@hermit.my
