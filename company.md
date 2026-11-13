# Hermit: company.md

Written for an investor's AI to read. Every claim links to something you can check: code, a transaction on NEAR
mainnet, a test log or a public build. Where something is early, we say so.

## One line

A wallet for iPhone and Mac with an AI assistant that runs on the device. You ask it in plain words to swap, bridge,
trade or pay; it prepares the move, and nothing leaves the wallet until you approve it with Face ID or Touch ID.

## The problem

- **AI in crypto wallets means sending your money life to someone's server.** Balances, positions, plans and
  addresses go to a cloud model with every question.
- **An AI that can move money needs limits a person can see and check.** Most agent products give the model a key
  and hope.
- **Cross-chain is still hard.** Getting from USDC on Base to NEAR, Solana or a Hyperliquid perp takes several apps
  and bridges.

## What we built

| Piece | What it does | Check it |
| --- | --- | --- |
| On-device model | Hermit 1.3 (Qwen3-4B fine-tune) and 1.3 Lite (Qwen3-1.7B) run on the phone or Mac with MLX. They answer with Wi-Fi off | [Hugging Face](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit), [results](docs/MODEL-RESULTS.md) |
| Wallet | EVM chains, Solana, NEAR, Bitcoin out, Hyperliquid. Keys stay in the device's Keychain | [HermitWallet](Packages/HermitKit/Sources/HermitWallet) |
| 30 tools | Swap, bridge, perps, spot on Solana, Aave, NEAR staking, batch payments from a spreadsheet, automations | [README](README.md#things-you-can-ask-it) |
| Review + approval | Every money move shows a review; Face ID or Touch ID signs it. The assistant prepares up to $100 per move by default | [README](README.md) |
| Private Cloud | Bigger questions go to NEAR AI Cloud only after the device checks the enclave's Intel TDX and NVIDIA proof | [docs/NEAR.md](docs/NEAR.md#private-cloud-on-near-ai-cloud) |
| In-app browser | Web apps on EVM, Solana and NEAR see a Hermit wallet; every request gets the same review | [Dapps](Packages/HermitKit/Sources/HermitWallet/Dapps) |

### Our three contracts on NEAR mainnet

- **[`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near):** an append-only registry of every
  Hermit model's hashes and test scores, which the app checks. It also keeps a salted fingerprint of each AI move a user
  approved. Only the hash goes on chain.
- **[`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near):** opt-in cover against the AI
  preparing the wrong move. 1 USDC for 30 days into a public pool. A claim must carry evidence that hashes to its Black
  Box fingerprint; an AI reviewer writes a verdict on chain, the owner decides, and only an approved claim can take
  money out. There is no admin withdraw.
- **[`hermit-guard.near`](https://nearblocks.io/address/hermit-guard.near):** an on-chain budget for agents and
  standing orders, with caps a key can't exceed.

## Where we are

Facts, as of 2026-11-13:

- **Stage:** alpha test version. Public builds: a notarized Mac download ([hermit.my/dmg](https://hermit.my/dmg)),
  iPhone and Mac on TestFlight. Not yet on the App Store.
- **Age:** the repository started on 2026-10-29. Two weeks of work, built for the NEAR hackathon.
- **Shipping pace:** 39 builds uploaded to TestFlight in two weeks, 24 for iPhone and 15 for Mac, each one
  through Apple's processing.
- **Mainnet use:** real swaps, staking, a Black Box record and an insurance purchase made from the app, each with a
  transaction link in the [README](README.md) and the contracts' DEPLOYMENTS.md files.
- **Revenue:** none yet. The app charges no fee of its own today. Insurance premiums go into the claims pool, not to
  us. We hold a NEAR Intents partner key, so a swap fee is a setting we can turn on later.
- **Users:** early testers through TestFlight and the waitlist at [hermit.my](https://hermit.my). We don't publish
  user numbers yet.
- **Tests:** 298 app tests passing in the [last full run](docs/logs/core-tests-2026-11-13.txt), plus unit and sandbox
  tests for each contract and CI on every push.
- **Open source:** MIT. The training data, generators, test suites and recipe are public in
  [hermit-training](https://github.com/Hermit-Ai-Labs/hermit-training).
- **AI-assisted:** much of the code, tests and docs were written with AI coding agents. We say this in the README too.

## How we'd make money

Not switched on yet. The options the product already supports:

1. A small fee on swaps and bridges through our NEAR Intents partner key.
2. Paid Private Cloud use beyond the free daily messages.
3. Underwriting margin on AI insurance once the pool is large enough to price.

## Model results

On held-out test conversations in a real tool loop ([full table](docs/MODEL-RESULTS.md)):

| Check | Hermit 1.3 | Hermit 1.3 Lite |
| --- | --- | --- |
| Says "done" without having done it | 0 of 1,801 | 8 of 1,843 |
| Never asks for a recovery phrase or key | 60 of 60 | 60 of 60 |
| No money call from injected text | 59 of 60 | 60 of 60 |
| Arguments traced to the user's words or a tool result | 99.8% | 100% |

## Team

- **Ryan Chi:** [X](https://x.com/MrRyanChi), [LinkedIn](https://www.linkedin.com/in/mrryanchi/), [ryanchi.com](https://www.ryanchi.com/)
- **Daksh Joshi:** [X](https://x.com/dakshbigshit), [LinkedIn](https://www.linkedin.com/in/joshidaksh/)

## Questions worth asking us

- How will a fee affect trust in an assistant that moves money?
- How does the insurance pool get priced and funded as users grow?
- What happens to on-device AI as phone models and chips improve?
- Why a wallet, and not an agent that plugs into existing wallets?

## Links

[Website](https://hermit.my) · [Mac download](https://hermit.my/dmg) ·
[iPhone TestFlight](https://testflight.apple.com/join/ed9vUh7d) · [Mac TestFlight](https://testflight.apple.com/join/P66H5DF8) ·
[Demo video](https://x.com/MrRyanChi/status/2121186366537244978) · [Docs](https://docs.hermit.my) ·
[Model](https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit) · contact@hermit.my
