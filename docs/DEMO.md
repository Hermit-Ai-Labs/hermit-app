# Demo video, X post and submission text

These are drafts. We record the video, post it and pick the final words and tracks ourselves. The rules say
screenshots aren't enough when judges can't open the demo, so the video matters.

## Video script (about 2 minutes 40 seconds)

Start with the problem, then real taps with real results. No intro, no architecture slides.

Before recording:

- Record on the Mac. Dropping a spreadsheet into the chat is easiest there, and the Touch ID prompt shows on screen.
- Fund one wallet with small mainnet amounts: about $40 of USDC on Base plus a little ETH for gas, about $10 of USDC
  on Solana plus 0.02 SOL, and one open Hyperliquid position of at least $10.
- Make `payees.csv` with three rows (`address,amount`), 1 USDC each, all wallets we own on Base.
- Put a NEAR AI key in Settings, Private Cloud, or use a build with the shared key.
- Let Hermit 1.2 finish downloading. Leave the assistant cap at $100 so shot 8 refuses.
- Turn on Do Not Disturb. Never show the recovery phrase, the API key or full addresses.

| # | Time | Tap and type | Say |
| --- | --- | --- | --- |
| 1 | 0:00 | Hermit on New chat, the model name showing "Hermit 1.2". | "An AI that helps with your money shouldn't send your money to someone's server. Hermit runs the AI on this Mac." |
| 2 | 0:08 | Type "swap 20 USDC on Base to NEAR". The step line reads "Getting a NEAR Intents quote for 20 USDC to NEAR", and the Swap review opens. Pause on the route "NEAR Intents (1Click)" and the policy lines ("Within daily limit", "Under the assistant's $100 per-move cap", "Pays out to your own address"). Approve with Touch ID and cut the wait (label it "sped up"). | "I ask in plain words. NEAR Intents finds the route, and Hermit checks the quote's signature here. The assistant can only prepare. Nothing moves until I approve." |
| 3 | 0:35 | Tap the model name, pick Private Cloud. The Home card reads "*model* in an enclave this Mac just verified". Ask "compare my NEAR swap fee with a typical exchange withdrawal fee". Tap the Verified in a TEE chip and scroll the checks. | "For a bigger model, NEAR AI Cloud runs it in a hardware enclave. Hermit checks the enclave's proof before a word leaves this Mac, and checks its signature on the answer." |
| 4 | 0:57 | Trade, Markets, Spot. Pick JUP, enter $5, pay with USDC, tap Swap, approve with Touch ID. Then Trade, Positions: JUP under "Solana tokens" with its cost and P&L. | "Spot on Solana through Jupiter, inside Hermit. It won't buy a token whose creator can freeze it unless Jupiter has verified it." |
| 5 | 1:17 | Trade, Markets, Perps, the market of the open position. Show the position card and the Close buttons. Then Trade, Positions, tap the position for the detail sheet. Don't close it. | "Perps on Hyperliquid. Close a quarter, half or all of it in one tap." |
| 6 | 1:30 | Automations. Tap "Every minute, tell me the BTC price and my wallet total", then Save. Cut to the "... ran" toast (label it "a minute later") and tap it. | "Automations run on this Mac while Hermit is open. If one ever needs to move money, it only prepares and waits for me." |
| 7 | 1:50 | New chat. Drop `payees.csv` in and type "send these". The step line "Checking 3 recipients for your review", then Review batch send with every row. Approve once. Each row turns to sent. | "Payroll from a spreadsheet. Hermit builds the batch from my own rows, so an address hidden somewhere else can't sneak in." |
| 8 | 2:18 | Type "swap 500 USDC on Base to NEAR". The reply says "The assistant can prepare up to $100 per move. Open Swap yourself for more." No review opens. | "And when it asks for more than I allowed, the policy says no." |
| 9 | 2:32 | End card: "Built at NEAR HACKATHON", hermit.my/dmg, the TestFlight links, github.com/Hermit-Ai-Labs/hermit-app. | |

Keep each wait under 12 seconds and label the cuts. Stick to Base USDC to NEAR in shot 2: on another pair Relay can win,
and then the review names Relay. If we'd rather not move funds in shot 2, stop at the approval sheet and caption it.
Export 1080x1920 for X.

## X post draft

The rules: say it was built at NEAR HACKATHON, tag @NEARProtocol and #NEARHackathon, attach the video.

Main post:

```text
An AI that helps with your money shouldn't read your money on someone else's server.

Hermit runs the AI on your device, moves money across chains through NEAR Intents, and checks a NEAR AI enclave's proof before using it.

Built at NEAR HACKATHON @NEARProtocol #NEARHackathon
```

Reply 1:

```text
What NEAR does in it:
- NEAR Intents: swaps and bridges across EVM, Solana, NEAR, BTC and Hyperliquid, and funding from any chain
- NEAR AI Cloud: a bigger model in a TEE, its proof checked on the device
- A NEAR account derived on the device
```

Reply 2:

```text
The AI can't hold keys. It only prepares moves: a $100 cap, swaps pay only you, Face ID or Touch ID every time.

Mac: https://hermit.my/dmg
iPhone: https://testflight.apple.com/join/ed9vUh7d
Code: https://github.com/Hermit-Ai-Labs/hermit-app

What cap would you give an AI with your money? @NearBuilders @NearLegion
```

## Submission `idea` draft (20 to 2000 characters)

```text
Problem: an AI assistant that helps with money has to see your balances, addresses and plans. Today that means a company's server reads all of it, or an agent holds keys it can be tricked into using.

Hermit is a wallet for iPhone and Mac with a private AI assistant. The model (Hermit 1.2, a Qwen3-4B fine-tune on MLX) runs on the device and works offline. The assistant can only prepare a move. A spending policy checks every move: a daily limit, a warning for new addresses, a $100 cap per assistant move, swap output only to the user's own addresses, and sends only to addresses the user typed. Tool results and files are treated as data, against prompt injection. The user approves every move with Face ID or Touch ID.

How NEAR fits in:
1) NEAR Intents (1Click) is the cross-chain engine: swaps and bridges across EVM chains, Solana, NEAR, Bitcoin and Hyperliquid, from the chat or the Swap screen, and funding from any chain through one-time deposit addresses. Quote signatures are checked on the device.
2) NEAR AI Cloud runs Private Cloud mode. Before each reply the device checks the enclave itself: the Intel TDX quote up to Intel's root, a fresh nonce, the signer, MRCONFIGID and RTMR3, a signed NVIDIA GPU verdict, and the TLS key. Then it checks the enclave's signature over the exact request and response.
3) Each wallet derives a NEAR account on the device for NEAR and NEP-141 balances and sends.

Also: Solana spot through Jupiter with token safety checks, Hyperliquid perps, Aave, a browser with injected wallets, automations, and batch sends from a spreadsheet.

Judges can check the NEAR parts on a Mac without the app: the scripts in near/ run a live dry quote, the NEAR key derivation and the NEAR AI Cloud attestation (23 checks pass without a key).
```

Check the length before pasting.

## Suggested tracks

We decide. HACKATHON.md says to list every track that fits.

| Track | Fit | Why |
| --- | --- | --- |
| `privacy` | Strong | On-device AI by default, and NEAR AI Cloud with the attestation checked on the device. Our deepest NEAR work. |
| `defi` | Strong | NEAR Intents is the swap, bridge and funding engine. Perps, spot and Aave sit on top. |
| `security` | Strong | The spending policy, an assistant that only prepares, and the attack demo in [SECURITY-DEMO.md](SECURITY-DEMO.md). |
| `realworld` | Possible | Batch sends from a spreadsheet and scheduled payments, though payroll isn't the core. |
| `agents` | Possible | It quotes and prepares payments through NEAR Intents and runs on a schedule. It doesn't earn or hire other agents. |
