# Hermit

## Overview: A local agentic wallet for iPhone and Mac

Hermit is a self-custody crypto wallet with an AI assistant that runs on your phone or laptop. You type a request, such
as "bridge 20 USDC to Arbitrum and put it in Aave" or "long ETH with $50 at 5x", and Hermit prepares the transactions
and shows you a review.

You own the wallet outright. Your recovery phrase is encrypted with a key held in the device's Secure Enclave, it never
syncs to iCloud and it never reaches our servers. The private key is only rebuilt in memory to sign a transaction you
approved with Face ID, Touch ID or your passcode, and it is wiped straight after. The AI can prepare a transaction but
has no way to sign one.

## Pain point: On-chain finance is too technical for most people to use well

Bridging, lending and leverage each need their own app and some know-how. AI assistants could do that work, but the
ones in wallets today send your balances and plans to someone else's server, and you have to trust whatever limits they
say they have.

## What we built: Our own on-device AI, 30 money tools and 3 live NEAR contracts

- **Our own model.** [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) runs offline on the
  device. In 1,801 tests it never reported a transaction as done when it wasn't, and in 60 attack attempts it never
  asked for a private key ([results](docs/MODEL-RESULTS.md)).
- **30 money tools** on EVM chains, Solana, NEAR, Bitcoin and Hyperliquid. Swaps and bridges go through NEAR Intents.
- **Private Cloud** for harder questions, on NEAR AI Cloud. The device verifies the server's secure-hardware proof
  before it sends anything, and keys are never sent.
- **3 contracts on NEAR mainnet.** [`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near) stores
  our model hashes and a fingerprint of each AI transaction.
  [`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near) sells 30 days of cover against AI
  mistakes for 1 USDC. [`hermit-guard.near`](https://nearblocks.io/address/hermit-guard.near) lets you give an agent a
  spending budget on chain.

## Progress: 39 app builds in two weeks, fully open source

39 TestFlight builds since late October (24 iPhone, 15 Mac). 4 models trained and published, with their hashes on
chain. 298 app tests passing ([log](docs/logs/core-tests-2026-11-13.txt)). The code is MIT licensed and the training
data is public ([hermit-training](https://github.com/Hermit-Ai-Labs/hermit-training)).

## Product: Live on iPhone and Mac today

<p>
<img src="docs/img/screens/offline.jpg" width="23%" alt="Hermit's home screen on iPhone: your own AI, works offline.">
<img src="docs/img/screens/swap.jpg" width="23%" alt="A swap review: 5 USDT to 1.37 NEAR via NEAR Intents.">
<img src="docs/img/screens/approve.jpg" width="23%" alt="The approval sheet, signed only after Face ID.">
<img src="docs/img/screens/proof.jpg" width="23%" alt="The Private Cloud proof sheet, checked on the phone.">
</p>

Try it: [Mac](https://hermit.my/dmg) · [iPhone TestFlight](https://testflight.apple.com/join/ed9vUh7d) ·
[Mac TestFlight](https://testflight.apple.com/join/P66H5DF8)

## Revenue model: Swap fees from users, licences from businesses

Most wallet revenue comes from swap fees (MetaMask, Phantom) and from business products (MetaMask Institutional,
Privy, Dynamic). We plan both. Hermit charges nothing today.

- **Users:** a small swap fee through our NEAR Intents partner key, and a paid tier of Private Cloud.
- **Businesses:** the Hermit SDK puts our AI and approval flow inside an exchange or fintech app, priced per monthly
  active user. We can also train a model on a company's own tools for a setup fee plus a licence. Other AI agents can
  pay to use Black Box, insurance and Guard.

## Team: Founders who have already built and scaled a trading agent

**[Ryan Chi](https://x.com/MrRyanChi)** ([site](https://www.ryanchi.com/)) co-founded
[insiders.bot](https://x.com/insidersdotbot), a prediction-market agent on Polymarket and Predict.fun that peaked at
US$360K ARR and $1M+ monthly volume. Guest lecturer on the HKU MBA. Co-president of 0xU Club, Hong Kong's largest Web3
student group. UPenn (FranklinDAO) and CUHK.

**[Daksh Joshi](https://x.com/dakshbigshit)** ([LinkedIn](https://www.linkedin.com/in/joshidaksh/)) co-founded
insiders.bot with Ryan, and Sigmaboy.ai. Technical BD at Astralane (low-latency trading infrastructure), formerly CPO at
PublicAI. Guest lecturer in Solidity and DeFi for a CUHK Business School master's course. CUHK finance and maths.

## FAQ: What investors usually ask us

**Won't a swap fee hurt trust?** The fee will show as its own line on the review screen before you approve. The AI
can't set the fee and can't sign.

**How is the insurance priced?** A flat 1 USDC for 30 days for now. All of it goes into a public pool that anyone can
add to, and money only leaves for an approved claim that matches its Black Box record. There is no admin withdrawal.
The price can be changed on the contract once we have real claims data.

**Why a wallet and not a plugin?** Our safety checks only work where the keys are. A plugin would have to hand signing
to someone else's wallet.

[hermit.my](https://hermit.my) · [Demo](https://x.com/MrRyanChi/status/2121186366537244978) · [Docs](https://docs.hermit.my) · contact@hermit.my
