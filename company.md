# Hermit

## Overview: A local agentic wallet for iPhone and Mac

Hermit is an agentic wallet: a self-custody crypto wallet run by a local AI that lives on your iPhone or Mac. You type
a request, such as "bridge 20 USDC to Arbitrum and put it in Aave" or "long ETH with $50 at 5x", and the local AI
prepares the transactions and shows you a review. Our goal is to democratise on-chain finance, so anyone can use
strategies that today need a technical background.

You own the wallet outright. Your recovery phrase is encrypted with a key held in the device's Secure Enclave, it never
syncs to iCloud and it never reaches our servers. The private key is only rebuilt in memory to sign a transaction you
approved with Face ID, Touch ID or your passcode, and it is wiped straight after. The AI can prepare a transaction but
has no way to sign one.

## Pain point: On-chain finance is too technical for most people to use well

Bridging, lending and leverage each need their own app and some know-how, and that technical threshold keeps most
people out. An agentic wallet can democratise this, but the AI in wallets today runs on someone else's server, so your
balances and plans leave your device and you have to trust whatever limits they say they have. Hermit's AI runs
locally, so none of that leaves your device.

## What we built: Our own local AI, 30 money tools and 3 live NEAR contracts

- **Our own local model.** [Hermit 1.3](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) runs locally and
  offline on the device. In 1,801 tests it never reported a transaction as done when it wasn't, and in 60 attack attempts it never
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

## Product: A live agentic wallet on iPhone and Mac today

<p>
<img src="docs/img/screens/offline.jpg" width="23%" alt="Hermit's home screen on iPhone: your own AI, works offline.">
<img src="docs/img/screens/swap.jpg" width="23%" alt="A swap review: 5 USDT to 1.37 NEAR via NEAR Intents.">
<img src="docs/img/screens/approve.jpg" width="23%" alt="The approval sheet, signed only after Face ID.">
<img src="docs/img/screens/proof.jpg" width="23%" alt="The Private Cloud proof sheet, checked on the phone.">
</p>

Try it: [Mac](https://hermit.my/dmg) · [iPhone TestFlight](https://testflight.apple.com/join/ed9vUh7d) ·
[Mac TestFlight](https://testflight.apple.com/join/P66H5DF8)

## Revenue model: Swap fees from users, licences from businesses

Wallets make money from swap fees (MetaMask, Phantom) and from business products (MetaMask Institutional, Privy,
Dynamic). Hermit earns from both. The app is free today.

- **Users** pay a small swap fee through our NEAR Intents partner key, and pay for Private Cloud above the free tier.
- **Businesses** license the Hermit SDK to run our local AI and approval flow inside their exchange or fintech app,
  priced per monthly active user. Companies with their own tools get a custom model trained on them, for a setup fee
  plus a licence. Other AI agents pay to use Black Box, insurance and Guard.

## Team: Founders who have already built and scaled a trading agent

**[Ryan Chi](https://x.com/MrRyanChi)** ([site](https://www.ryanchi.com/)) co-founded
[insiders.bot](https://x.com/insidersdotbot), a prediction-market agent on Polymarket and Predict.fun that peaked at
US$360K ARR and $1M+ monthly volume. Guest lecturer on the HKU MBA. Co-president of 0xU Club, Hong Kong's largest Web3
student group. UPenn (FranklinDAO) and CUHK.

**[Daksh Joshi](https://x.com/dakshbigshit)** ([LinkedIn](https://www.linkedin.com/in/joshidaksh/)) co-founded
insiders.bot with Ryan, and Sigmaboy.ai. Technical BD at Astralane (low-latency trading infrastructure), formerly CPO at
PublicAI. Guest lecturer in Solidity and DeFi for a CUHK Business School master's course. CUHK finance and maths.

## FAQ: What investors usually ask us

**Won't a swap fee hurt trust?** The fee shows as its own line on the review screen before you approve. The AI
can't set the fee and can't sign.

**How is the insurance priced?** A flat 1 USDC for 30 days. All of it goes into a public pool that anyone can
add to, and money only leaves for an approved claim that matches its Black Box record. There is no admin withdrawal.
We set the price on the contract and adjust it as claims data comes in.

**Why an agentic wallet and not a plugin?** Our safety checks live where the keys are, with the local AI right next to them.
A plugin hands signing to someone else's wallet, and those guarantees go with it.

[hermit.my](https://hermit.my) · [Demo](https://x.com/MrRyanChi/status/2121186366537244978) · [Docs](https://docs.hermit.my) · contact@hermit.my
