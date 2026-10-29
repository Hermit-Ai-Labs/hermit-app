# Shipping the Hermit Mac app

The Mac app is the web demo (hermit-demo) running in a native macOS window. Same React UI, same look,
pixel for pixel. Underneath, a small Rust side does the things a web page must never do: run the
model, hold the keys, sign transactions.

## Stack

| Part | Choice | Why |
|---|---|---|
| App shell | **Tauri 2** (Rust + the system WebKit) | Reuses the demo UI as is. ~15 MB app instead of ~200 MB with Electron. Rust side for keys and signing. |
| UI | The demo's React app (`src/`) | It already is the spec. Mocks get swapped for real calls one flow at a time. |
| Model | **llama.cpp** (`llama-server`, Metal) bundled as a sidecar | Runs GGUF models on the Mac's GPU, OpenAI-style API on 127.0.0.1 only. The model is downloaded on first launch. |
| Keys | Generated in Rust, stored in the **macOS Keychain**, unlocked with **Touch ID** | The approval sheet's fingerprint becomes a real Touch ID prompt. Keys never enter the web view. |
| Chain | **Base**, USDC first (send, schedule, x402) | Matches the demo's Pay flow. Testnet (Base Sepolia) until the signer is audited. |
| Builds | GitHub Actions macOS runner, `.github/workflows/mac.yml` | Our server is Linux; Apple's tools only run on macOS. Universal build (Apple Silicon + Intel). |
| Distribution | Signed + notarized `.dmg`, auto-updates from GitHub Releases | Not the Mac App Store: its sandbox fights a bundled model server and a wallet. |

## Milestones

**M0. The shell (this week)**
- [x] Demo UI inside a native window, traffic lights over the sidebar, drag strip, no demo stage.
- [x] Fonts bundled, so it looks right offline.
- [x] App icon (placeholder from the mark).
- [x] CI builds an unsigned universal `.dmg`.
- [ ] Team installs it on their Macs and checks every page against the web demo.

**M1. Real local chat**
- Model sheet: download (with progress), pick, delete. Start with a 2B model in Q4 (~1.5 GB).
- `llama-server` sidecar starts with the app, stops with it, listens on 127.0.0.1 only.
- Chat streams real replies. Scripted demo replies stay for the money flows until M3.
- Works with Wi-Fi off.

**M2. Real wallet**
- Create / import (recovery phrase) a local wallet. Keychain + Touch ID.
- Real balances and activity on Base.
- Send USDC through the approval sheet: simulate, hazard scan, Touch ID, sign, broadcast. Testnet first.

**M3. The agent does errands**
- The scripted scenarios become tool calls the model makes: pay, schedule, swap, deposit.
- Every tool that moves money goes through `approve()`. No silent spending, ever.
- Hazard scan does real checks (simulation, known address, contract verified, amount, limits).

**M4. Beta**
- Apple Developer ID signing + notarization, auto-update, crash reports (opt-in).
- Ship to the waitlist in waves.

## Needed from the team
1. **Apple Developer Program** account ($99/yr). For a company name on the signature, enroll as an
   organisation (needs a D-U-N-S number, takes days to weeks, so start now).
2. **Macs to test on:** at least one Apple Silicon Mac. Intel is optional.
3. **Model call:** which model ships first (we have benchmarks in hermit-lab: Qwen3.5 2B, Woof 2B, Phi-4 mini).
4. **Sign-in:** does the Mac app need an account at all for the beta? Local-first suggests no.

## Running it
```bash
npm install
npm run dev          # the UI alone in a browser, http://localhost:5173
npm run app          # the Mac app with hot reload (needs a Mac with Xcode command line tools + Rust)
npm run app:build    # Hermit.app and Hermit.dmg in src-tauri/target/release/bundle/
```
The UI is synced from hermit-demo (base commit in `.demo-base`). Design changes land in hermit-demo
first, then get pulled here.
