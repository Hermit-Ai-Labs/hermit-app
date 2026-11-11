# Submission

The rules are at https://nearhackathon.com/HACKATHON.md. We read them on 2026-11-11; read them again before sending,
because they can change. The deadline is 2026-11-14 23:59 UTC, and the repository has to be public by then. Each
project gets one submission. Mistakes are fixed at https://nearhackathon.com/request-changes, never by sending again.

`HUMAN: confirm Hermit hasn't been submitted yet, by API or at https://nearhackathon.com/#apply.`

## For the judges

Our first commit is from 2026-10-29, after the 2026-10-19 announcement, so the whole repository was built in the
window (Q-001). That commit (tag `pre-hackathon`, `266b8d3`) brought over the look of our earlier web demo. Its
`.demo-base` file names the demo's commit `9314dbb` from 2026-10-27, and the demo itself started on 2026-10-26.

We built the wallet, the on-device chat and the other chains (EVM, Solana, Hyperliquid, Relay) first (Q-002, Q-004).
The NEAR work starts after commit `8fe7b71` on 2026-11-08: Private Cloud on NEAR AI Cloud, the NEAR account, NEAR
Intents, the spending policy, the `near/` scripts and these docs. Spot and Memes, Earn, Explore, automations and batch
sends came after that, still inside the window. Today `main` and `near-hackathon` point at the same commit.

The diffs, for Q-003:

- Everything: https://github.com/Hermit-Ai-Labs/hermit-app/compare/pre-hackathon...main
- The NEAR work: https://github.com/Hermit-Ai-Labs/hermit-app/compare/8fe7b71...main

Once the `hackathon-submission` tag exists, put it in place of `main` in both links.

The app uses swift-secp256k1 0.23.2, CryptoSwift 1.9.0, mlx-swift 0.32.3, mlx-swift-lm 3.32.3 and swift-transformers
1.3.5 (Q-005), plus Apple's CryptoKit, Security, LocalAuthentication, PDFKit, Vision, WebKit, EventKit and
UserNotifications, and the Newsreader font (OFL). The scripts use requests, cryptography, eth-account and dcap-qvl,
plus nearai-inference-sdk for `--sdk`. The services we call are NEAR Intents 1Click, NEAR AI Cloud, NVIDIA NRAS,
Relay, Jupiter, Hyperliquid, Polymarket, Aave v3, DefiLlama, CoinGecko, Binance, FinancialModelingPrep, Etherscan,
Blockscout, NearBlocks, FastNEAR and other public RPCs, DuckDuckGo, wsrv.nl, CoinCap and the Filebase and Pinata IPFS
gateways (logos), and models.hermit.my, Hugging Face and ModelScope (model downloads). We checked test vectors against near-seed-phrase 0.2.1, near-api-js 4,
@defuse-protocol/one-click-sdk-typescript 0.1.26 and solders; the app uses none of them at runtime. There are no
templates or boilerplate. On the device, Hermit 1.2 is our LoRA fine-tune of Qwen3-4B-Instruct-2507, and Hermit 1.1
Lite is Qwen3-1.7B as mlx-community's 4-bit weights, not fine-tuned (both Apache-2.0, at
https://huggingface.co/rahulol). Private Cloud uses NEAR AI Cloud's models, `Qwen/Qwen3.8-27B` by default. We wrote
much of the code, tests and docs with AI coding agents (Claude Code), and we direct and review that work. Commits are
authored as "Hermit".

`HUMAN: for Q-015, name any other NEAR HACKATHON project by the same people, or write "none". If there is one, the
README has to name it too.`

## Checklist

| What | Status |
| --- | --- |
| Repository public | Done. GitHub reports it public with an MIT license on 2026-11-11. It has to stay public through judging. |
| LICENSE file | Done (MIT). |
| Latest work pushed | Left. `origin/main` and `origin/near-hackathon` are both at `e18a524`. The 2026-11-11 doc edits aren't committed yet. |
| `hackathon-submission` tag | Left. `HUMAN: create and push it, then open both diff links.` |
| README with "do X, see Y" steps | Done. The Python steps in [VERIFY.md](VERIFY.md) were run in a fresh clone on 2026-11-11. |
| Test log for the current tree | Left. The 2026-11-11 run ended with 182 tests, 13 skipped, 0 failures. `MAC: save a bash scripts/core-tests.sh run as docs/logs/core-tests-2026-11-11.txt.` |
| Downloads up until at least 2026-11-18 | Done, keep them up. hermit.my/dmg and both TestFlight links opened on 2026-11-11. TestFlight builds expire 90 days after upload. |
| Shared keys in the TestFlight builds | `HUMAN: say whether the current builds carry Hermit's shared NEAR AI key and 1Click partner key.` |
| Demo video | Left. Script in [DEMO.md](DEMO.md). |
| X post: "built at NEAR HACKATHON", @NEARProtocol, #NEARHackathon, video attached | Left. We post it, then put the link in the README. |
| No secrets in git | Done. The bundled key files are in `.gitignore`, and git tracks none of them. |

## The fields only we decide

The rules say not to guess any of these.

| Field | Rule | Value |
| --- | --- | --- |
| Project name | 2 to 80 characters | `HUMAN` |
| Team lead's name | 2 to 80 characters | `HUMAN` |
| Contact email | valid, at most 160 characters | `HUMAN` |
| Team size | exactly `1`, `2 - 4`, `4 - 6`, `6 - 8` or `8+` | `HUMAN` |
| Tracks | ids from HACKATHON.md, every one that fits. Our suggestions are in [DEMO.md](DEMO.md). | `HUMAN` |
| NEAR payout account | mainnet, created by us in a NEAR wallet. Never the test account from `near/near-account.py`: its phrase is public. | `HUMAN` |
| Repository link | https://github.com/Hermit-Ai-Labs/hermit-app | `HUMAN` |
| Demo post link | the public X post | `HUMAN` |
| What we built (`idea`) | 20 to 2000 characters. A draft is in [DEMO.md](DEMO.md). | `HUMAN` |
| Consent | read verbatim: "I agree that the organizers may use these details to review our submission and contact us about this hackathon." | `HUMAN` |

## Sending it

Make the `requestId` once with `uuidgen | tr A-Z a-z` and reuse it on any retry. Keep `payload.json` outside the
repository, since it holds personal data. It has exactly these 11 fields, and never a `website` field (that's a spam
trap):

```json
{"requestId": "", "projectName": "", "leadName": "", "email": "", "size": "", "tracks": [],
 "nearAddress": "", "projectUrl": "", "demoUrl": "", "idea": "", "consent": true}
```

Show it to the team, and send it only after they say yes:

```sh
curl -sS -X POST https://nearhackathon.com/api/applications \
  -H 'Content-Type: application/json' --data-binary @payload.json -w '\nHTTP %{http_code}\n'
```

201 means it's saved. 400 lists the fields to fix; resend with the same `requestId`. 503 means wait a minute and resend
the same way. 403 and 409 mean stop and read HACKATHON.md: don't change the link or the email to get around them.

`grep -rn 'HUMAN\|MAC:' README.md docs near` lists every line still to fill.
