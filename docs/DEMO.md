# Demo video, X post and submission text

Everything in this file is a draft for the team. The team records the video, publishes the post and decides the final
wording and tracks.

## 1. Demo video: shot list (60 to 90 seconds, iPhone screen recording)

Goal: show one complete moment, from a real request to a visible result. Start with the user's problem. Skip intros and
architecture slides.

Before recording:

- Use a wallet with about $25 of USDC on Base, so the swap can actually go through. If you'd rather not move funds,
  stop at the approval sheet in shot 4 and say so in a caption.
- Use a NEAR AI key, or a build with the shared key.
- Let the on-device model finish downloading (it starts by itself on first launch).
- Clear notifications and turn on Do Not Disturb. Hide balances you don't want to show.
- Use iOS Screen Recording with the microphone off. Captions are added in the edit.

| # | Time | On screen | Caption / voice-over |
| --- | --- | --- | --- |
| 1 | 0:00–0:06 | The Hermit home screen, the chat box empty. | "Your AI wallet assistant shouldn't send your balances to someone's server." |
| 2 | 0:06–0:14 | Type **"swap 20 USDC on Base to NEAR"** and send. The step line appears: "Getting a NEAR Intents quote for 20 USDC to NEAR…" | "Hermit's AI runs on the phone. Ask it in plain words." |
| 3 | 0:14–0:24 | The answer with the quote (amount of NEAR, fee, about 35 s). The Swap review opens prefilled. Pause on the route line, "NEAR Intents (1Click)", and on the policy checks: within the daily limit, under the assistant's $100 cap, pays out to your own address. | "NEAR Intents finds the route across chains. The quote's signature is checked on the phone. The assistant can only prepare. A spending policy caps what it can do." |
| 4 | 0:24–0:34 | Tap **Review**. The approval sheet appears. Approve with **Face ID**. | "Nothing moves until you approve with Face ID." |
| 5 | 0:34–0:46 | The status tracker steps through: deposit, seen, solvers filling, **Delivered**. Speed it up 4 to 8 times in the edit, with a small "sped up" label. End on the NEAR balance going up in Wallets. | "Settled through NEAR Intents. The NEAR lands in an account derived on this phone." |
| 6 | 0:46–0:52 | Optional, the guard in action: ask **"swap 500 USDC on Base to NEAR"**. You see "The assistant can prepare up to $100 per move." | "Ask for too much, and the policy says no before any screen opens." |
| 7 | 0:52–1:06 | Tap the model name and choose **Private Cloud**. The Home card reads "… in an enclave this phone just verified". Ask a longer question. Tap the **Verified in a TEE** chip and scroll the sheet: Intel TDX quote, nonce, MRCONFIGID, RTMR3, GPU, TLS, response signature. | "Need a bigger model? NEAR AI Cloud runs it in a hardware enclave. The phone checks the enclave's proof before it sends a word, and checks the signature on the answer." |
| 8 | 1:06–1:18 | Swipe down to Control Center and turn on **Airplane mode**. Switch back to **On-device** and ask "what did I just swap?". It answers. | "And with no network at all, it still works." |
| 9 | 1:18–1:25 | End card: Hermit logo, "Built at NEAR HACKATHON", the TestFlight link, `github.com/Hermit-Ai-Labs/hermit-app`. | none |

Notes:

- Keep each shot under 12 seconds. If the real swap takes longer than about 40 s, cut the wait instead of speeding up
  the whole clip.
- Don't show the recovery phrase, the API key or full addresses.
- Export in 1080×1920 for X, plus a 16:9 version with the phone centred if you want it for YouTube.

## 2. X post: draft

Rules from HACKATHON.md: say the project was built at NEAR HACKATHON, tag @NEARProtocol and #NEARHackathon, and attach
the video. Lead with the problem, give NEAR's role concretely, and end with the links and a real question.
@NearLegion and @NearBuilders are optional.

**Main post** (under 280 characters, so it works without X Premium):

```text
An AI that helps with your money shouldn't read your money on someone else's server.

Hermit runs the AI on your iPhone, swaps across chains through NEAR Intents, and checks a NEAR AI enclave's proof before using it.

Built at NEAR HACKATHON @NEARProtocol #NEARHackathon
```

**Reply 1** (what NEAR does):

```text
What NEAR does in it:
- NEAR Intents: one swap screen for EVM, Solana, NEAR, BTC and Hyperliquid, and add funds from any chain
- NEAR AI Cloud: a bigger model in a TEE, its proof checked on the phone
- A NEAR account derived on the phone
```

**Reply 2** (safety, and the ask):

```text
The AI can't hold keys. It only prepares moves: a $100 cap, swaps pay only you, Face ID every time. Injection tests in the repo.

iPhone beta: https://testflight.apple.com/join/ed9vUh7d
Code: https://github.com/Hermit-Ai-Labs/hermit-app

What cap would you give an AI with your money? @NearBuilders @NearLegion
```

Before posting, check that the video is attached to the main post, that the links work, and that the Mac TestFlight
link is added only after Apple approves it.

## 3. Submission `idea` text (20 to 2000 characters)

About 1,600 characters. Paste it as is or edit it.

```text
Problem: an AI assistant that helps with money has to see your balances, addresses and plans. Today that means a company's server reads all of it, or an agent holds keys it can be tricked into using.

Hermit is a self-custody wallet for iPhone and Mac with a private AI assistant. The model (Qwen3-4B, MLX) runs on the phone and works in flight mode. The assistant can only prepare a move. A spending policy checks every move: a daily limit, a warning for new addresses, a $100 cap per assistant move, swap output only to the user's own addresses, and sends only to addresses the user typed. Tool results are treated as data, against prompt injection. The user approves every move with Face ID.

How NEAR fits in:
1) NEAR Intents (1Click API) is the cross-chain engine. It handles swaps and bridges across EVM chains, Solana, NEAR, Bitcoin and Hyperliquid, and "add funds from any chain" through one-time deposit addresses. Quote signatures are checked on the phone, and statuses are tracked through REFUNDED and FAILED.
2) NEAR AI Cloud powers Private Cloud mode. Before each prompt, the phone verifies the enclave itself: the Intel TDX quote to Intel's root, a fresh nonce, the signer binding, MRCONFIGID and RTMR3 replay, the GPU evidence with NVIDIA NRAS, and the TLS key binding. Then it checks the enclave's signature over the exact request and response bytes.
3) Each wallet derives a NEAR account on the phone (m/44'/397'/0') for NEAR and NEP-141 balances and sends.

Judges can check it on Linux: scripts in near/ run a live dry quote, the NEAR key derivation, and an attestation verification of the NEAR AI Cloud enclave (23 checks, or 27 with an API key).
```

## 4. Suggested tracks (the team decides)

| Track id | Fit | Why |
| --- | --- | --- |
| `privacy` | Strong | On-device AI by default. NEAR AI Cloud TEE inference with the attestation verified on the device, and response signatures. This is the deepest NEAR work in the project. |
| `defi` | Strong | NEAR Intents 1Click is the swap, bridge and funding engine across EVM, Solana, NEAR, BTC and Hyperliquid, with dry-run quotes and handling for REFUNDED and FAILED. |
| `security` | Strong | Spending policy, an assistant that only prepares, a guard against prompt injection, and an attack demo with a log ([SECURITY-DEMO.md](SECURITY-DEMO.md)). Function-call keys are not used (see the limits there). |
| `agents` | Possible | The assistant calls tools that quote and prepare payments through NEAR Intents. But it doesn't earn, hire other agents or pay for APIs, which is the core of that track. |
| `open` | Possible | It doesn't fit one category neatly. |

Several tracks are allowed in one submission. HACKATHON.md says to list "every track the project fits".
