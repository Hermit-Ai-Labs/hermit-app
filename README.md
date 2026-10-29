# Hermit — product demo and design spec

Hermit is a **private, local-first AI assistant with native wallets**. It trades, earns, pays and builds for you, and asks before any money moves. Think Claude or Manus, but crypto-native.

This repo is a **clickable frontend demo**. Every number, chat reply and transaction is mocked. Nothing touches a chain, a model or a server. Its job is to show *exactly* how the product should look, read and behave, down to small details. This README explains the intent behind those details so they survive the real build.

| | |
|---|---|
| Live demo | https://hermit-demo.vercel.app |
| Skip the login | https://hermit-demo.vercel.app/?skiplogin |
| Screenshots of every screen (desktop and phone) with notes | `handoff/` folder (`handoff/index.html`) |
| Figma spec (tokens, components, 3 rebuilt screens) | https://www.figma.com/design/vDyL50SaQTTyg7peAx2oek |

> The `handoff/` screenshots and the Figma file were made **before** the latest round of changes (tabs, Markets terminal, wallet dropdown, file viewer, automations, login). When they disagree with the live demo, **the live demo and this README win.**

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # outputs dist/
```

Every push to `main` deploys to Vercel automatically.

---

## 1. Design principles (the non-negotiables)

These came from many review rounds. Please treat them as rules.

1. **Ultra-minimal and high-end, like Claude, Manus and Canva.** Pure white background, lots of space, monochrome UI with one accent. If a word, badge or block doesn't help the user, remove it.
2. **Copy is short and plain.** One line beats two. No marketing filler. No `·` (middle dot) separators anywhere; they read as AI-generated. Use commas or line breaks.
3. **The logo is the mark only.** Never put the word "Hermit" next to it.
4. **Real logos everywhere.** Every token, DApp, chain, venue and app shows its real logo (`public/logos`), never a letter placeholder. When something new is added (a pair, a venue), add its logo.
5. **Purple (`#4E1F96`) is reserved for key actions:** Approve, Ask, New chat, primary brand buttons, low-gas top-up, active badges. Everything else is black, greys and white.
6. **Chat first.** Users do things by talking to Hermit. Trade, Earn and Payments show *the results* of what the agent executed, and allow hands-on control.
7. **Every money move goes through one approval sheet** with a hazard scan and passkey. No silent spending, ever.
8. **Every button has an outcome.** Nothing is dead. In chat, an action button posts the user's action as a message and Hermit replies (e.g. *Run daily* → "Run daily set. I will finish open Monad quests every day at 08:00…"). Elsewhere, buttons open a sheet, change state or show a toast.
9. **Numbers come with a chart.** When the agent mentions numbers, a fitting chart sits beside the text (bars, donut, area, candles).
10. **Price charts are always candlesticks.** This includes the mini charts in lists. Balance, PnL and APY curves may stay as lines because they are not prices.
11. **One tab row per page.** Each section of a long page is its own tab. On phones the tab row is a single row that scrolls sideways and sticks to the top. Never stack two rows of tabs; secondary choices (like the wallet picker) become a dropdown or an inline segmented control.
12. **Phones never scroll sideways.** Nothing may overflow horizontally at 320px. Text truncates or wraps, rows compress.
13. **Everything looks comfortable.** Dropdown chevrons have breathing room, cards in a row share the same height, icon rows are evenly spaced and aligned with the text above.

### QA routine used for every change
After every UI change the demo was checked in **at least 3 rounds** at **320, 375, 1100 and 1280px**:
- No horizontal page scroll, no element past the screen edge, no clipped text, no `·`.
- Every button on every page and tab is clicked; anything that changes nothing is a bug (an already-active tab is the only allowed exception).
- Visual pass with screenshots on desktop and phone.

---

## 2. Brand and tokens

| Token | Value | Use |
|---|---|---|
| `--bg` | `#FFFFFF` | Page background (pure white) |
| `--subtle` | `#FAFAF9` | Sidebar, light panels |
| `--hover` | `#F5F5F4` | Hover, segmented control track, icon circles |
| `--border` | `#ECECEB` | All 1px borders |
| `--text` | `#121212` | Primary text, black buttons |
| `--muted` | `#6B6B6B` | Secondary text |
| `--faint` | `#A3A3A3` | Labels, timestamps |
| `--accent` | `#4E1F96` | Hermit purple, key actions only |
| `--green` / `--red` / `--amber` | `#15803D` / `#C53030` / `#A16207` | Gains, losses, warnings (each with a `-soft` tint) |
| `--radius` | `14px` | Cards (sheets 20px, pills 99px) |

- **Type:** Inter for UI. **Newsreader** (serif) for the home greeting and the login headline. JetBrains Mono for addresses and code.
- **Logo:** `src/components/Logo.jsx` (SVG mark, purple stroke).
- **Mascot:** the voxel hermit crab. `public/hermit-hero.png` (transparent) sits above the home greeting. The login film (`public/login-film.mp4`) shows it travelling the world.
- **Demo background:** painted purple with grain, like hermit.my (`src/components/Stage.jsx`).

---

## 3. How the app is built

- **Stack:** Vite + React 18, plain CSS in `src/styles.css` (tokens on `:root`), `lucide-react` icons, hand-written SVG charts. No UI kit.
- **Routing:** hash routes, `#/page` or `#/page/tab` (e.g. `#/trade/markets`), so every tab can be linked to directly. Changing tabs replaces history and scrolls to the top.
- **State:** one React context, `useApp()` in `src/App.jsx`. It holds messages, approvals, earn and trade positions, memory (hermit.md), projects and project.md, to-dos, automations, chart marks, open files, the project a chat belongs to, toggled-off project costs, and sign-in.
- **Breakpoint:** 860px. Above it, desktop (sidebar). Below it, phone (bottom tab bar, sheets slide up from the bottom).
- **The demo stage:** on a wide screen without `?embed=1`, the app runs on the painted purple background in one of three views, picked with the small pill at the top right: **PC** (a desktop window with close, minimise, fullscreen), **Phone**, or **Chrome extension** (a browser showing a news article, with Hermit docked in the side panel in its mobile layout and aware of the page: "On this page", Summarize this page, Trade this news). The app itself runs in an iframe with `?embed=1` (`&ext=1` for the side panel).
- **URL flags:** `?embed=1` renders the bare app. `?skiplogin` opens the app without the login page.
- **Local storage:** `hermit-auth` (signed in), `hermit-stage` (PC or phone).

| What | Where |
|---|---|
| Scripted agent replies (`{ tools, blocks }`) and the prompt matcher | `src/scenarios.jsx` |
| Replies built on the fly (attachments, "add to memory") | `src/replies.jsx` |
| Saved conversations (project chats, recents) | `src/threads.jsx` |
| Chat cards (token chart, news, opportunities, receipts…) | `src/components/ChatCards.jsx` |
| All mock data | `src/data.js` |
| Approval sheet + hazard scan | `src/components/Approval.jsx` |
| Page tabs + URL tab hook | `src/components/Tabs.jsx` |
| Sheets (attach, files, record, add wallet, token, schedule, MCP, model…) | `src/components/Sheets.jsx` |
| File viewer | `src/components/FileViewer.jsx` |
| Sign-in flows for X, Discord, Telegram, Google, GitHub | `src/components/ConnectSheet.jsx` |
| Login page | `src/components/Login.jsx` |
| Logo lookup (name → file) | `src/components/Mark.jsx` |

### The approval spec
Anything that moves money calls `approve(spec)`:

```js
approve({
  kind: 'Perp order on Hyperliquid',      // small label at the top
  title: 'Long HYPE 3x',                  // what is being approved
  lines: [['Margin', '$500'], ['Take profit', '$27.43']],  // summary rows
  checks: baseChecks([...]),              // hazard scan items: pass | warn | fail
  note: 'Leveraged…',                     // optional banner
  success: 'Order filled',                // toast after approval
  result: { title, rows, stats },         // optional receipt card posted into chat
  adds: { trade: [...], earn: [...] },    // positions that appear in Trade / Earn
  onSuccess: () => {},                    // any page state to update (e.g. gas refilled)
})
```
The sheet animates the hazard checks one by one, then shows Cancel and a purple **Approve** button with a fingerprint icon (passkey). On a phone it is a bottom sheet, on desktop a dialog. After approval, a receipt posts into chat if you are in chat.

---

## 4. Login

Modelled on Claude's sign-in page, but with Hermit branding.

- **Left:** logo top-left. Large serif headline **"Your almighty intern"**, subline **"Pay, earn and build in one place. Fully private."** A soft card with Continue with Google, Continue with Apple, OR, email field, black Continue with email, and the line "Keys stay on your device. Hermit never holds your funds." Under it, Download desktop app.
- **Right (desktop only):** a tall rounded panel playing the hermit-crab film, muted, looping, covering the panel.
- **Flows:** Google and Apple show "Signing in…" then open the app. Email goes to "Check your email" with six code boxes and **Use demo code**. Log out (account menu) returns here.
- **Phone:** single centered column, no film.

### The film
Made with Higgsfield, **Seedance 2.5**, 15s, 720p, 3:4, no audio, with the crab image as the identity reference. Five shots, styled like a luxury fashion-house travel campaign: Paris café with an espresso (Eiffel Tower), Tokyo Shibuya crossing at night, laptop on a bench at the New York Stock Exchange, a Giza dune at sunset, a Santorini rooftop at blue hour. Then:
- a 0.8s dissolve from the last frame into the first so the loop is seamless (14.3s),
- a cinematic grade: filmic S-curve with lifted blacks, slightly lower saturation, cool shadows and warm highlights, soft vignette, fine grain.

The ungraded 15s original is `handoff/login-film-original.mp4`. If the video fails to play, the panel falls back to the still illustration.

---

## 5. Desktop sidebar (Claude-style)

From top to bottom:
1. **Logo** (mark only).
2. **Under management** card: total funds the agent manages (e.g. $48,320, +2.6%), always visible. Clicking opens Wallets.
3. **New chat** (purple + icon). There is no "Chat" item; a new chat is the entry point.
4. **Main nav:** Projects, Automations, Trade, Earn, Payments (with a count of things waiting), Explore, Calendar.
5. **Projects:** expandable like Claude. The chevron shows that project's chats underneath. Clicking the name opens the project.
6. **Recents:** standalone chats.
7. **Account footer, pinned to the bottom:** avatar, name, wallet mode, and a wallet shortcut icon. Clicking the account opens a menu above it: email, **Wallets** (with balance), **Files**, **Connectors**, **Settings** (⌘,), Get help, Log out. These four pages live here because they are used less and the nav was too long.

**Phones:** bottom tab bar with five icons: Chat, Trade, Earn, Payments, Wallets. The menu icon (top left) opens the same sidebar as a drawer. The pencil icon (top right) starts a new chat.

**Ask Hermit:** a round black button with a sparkle, bottom right, on every page except chat and automation threads. It opens a page-aware assistant (side panel on desktop, bottom sheet on phone) with **suggested questions specific to that page**, for example:
- Explore: "Top DApps with money-making opportunities today?"
- Trade: "Mark support and resistance" (draws on the chart), "Is my HYPE stop too tight?"
- Calendar: "Plan my day around the market", "Find time for a 1-hour deep work block" (adds it)
- Files: "Find my Figma invoice" (opens it in the viewer)
- Projects, Automations, Settings, Connectors, Earn, Payments, Wallets each have their own.
Free text the panel can't handle hands off to full chat.

---

## 6. Chat

### The chat box (same everywhere: home, chat, project pages, automations)
Like Claude and ChatGPT. Left: **+**, **attach file** (paperclip), **speak** (mic). Right: model label and send.
The **+** menu: *Add files or photos*, *Commands* (/trade, /swap, /pay, /earn, /automate, /remember; typing "/" in the box opens the same list), *Project* (puts the chat in a project, shown as a strip under the box), *Connectors* (on/off toggles, Manage connectors), *Plugins* (skills with toggles, Browse plugins). Code: `src/components/ChatInput.jsx`.

### Home (new chat)
- Hermit illustration, serif greeting ("Good afternoon, Ryan").
- **Phantom-style wallet actions under the greeting:** Send, Swap, Receive, Buy. Money moves sit right next to the AI.
- Four small example chips: Trade the news, DeFi ideas, Build a bot, Join a presale. On phones they stay on **one line** and scroll sideways.
- Two cards: **Managed by agent** (donut + total, opens Wallets) and **Today** (to-dos; checkbox completes, the row opens where the task lives). Both can be hidden in Settings › Home.
- Phones also list Projects at the bottom, because there is no sidebar.

### Chat inside a project
Starting **New chat** from a project page makes the chat belong to that project:
- a **back link** to the project at the top,
- the **project name in a strip under the chat box** (like Claude; × detaches it),
- the Managed by agent and Today cards show **only that project** (its money, expected monthly gain, burn rate, its to-dos).
Any project chat, new or old, keeps the back link at the top.

### How agent replies look
Each reply shows collapsible tool steps ("Reading 1,200 headlines…", then "3 steps ✓"), then cards appear one by one. Demo prompts (type them or use chips):

| Prompt | What it shows |
|---|---|
| What news is moving the market today? | Move bars, **Top stories** (see below) |
| Tell me more about the ETH ETF staking approval | Candle chart since the news, X sentiment, suggested trade |
| Should I buy $PENGU? | Candle chart with indicators from memory, holder bubble map, KOLs, Buy |
| Best safe yield for 10k USDC? | Yield bars, plan timeline, Execute → approval → receipt, deposits appear in Earn |
| Long HYPE 5x on Hyperliquid, stop at $22 | Perp ticket with TP/SL |
| Build a Telegram bot that sends me HYPE news every morning | **Agent pays for an API itself** within a dev budget, code, cost bars, Deploy needs approval |
| Reverse engineer this 24% USDC vault: 0x9c4e…a71b | Yield split by source, how it works, stress test, safer rebuild |
| What DeFi opportunities should I look at? | Ranked bars, opportunity list, full catalog |
| Which coins are volatile enough to trade right now? | Movers |
| Farm the Monad airdrop for me | Quest list, Review post, **Run daily** |
| Draw how my funding-rate arb bot works | Flow timeline |
| Summarize my inbox and pay what is due | Inbox card, pay with approval |
| Pay alice.eth 200 USDC on Friday | Scheduled payment |
| Join the presale at legion-sale.xyz/hermes | **Prompt injection blocked**: hidden instructions on the page are shown and refused, the real sale is offered with approval |
| The budgeting app frontend is done. Wire up the APIs. | **Developer flow:** build progress, then OpenAI's billing page opens **in a tab inside Hermit**; pay in USDC (x402) → the API key appears, saved to `.env.local` and the vault; code + test results |
| Send USDC to every wallet in this spreadsheet (attach `wallets.xlsx`) | **Batch send:** 48 recipients, 1 invalid removed, sanctions and duplicate checks, **private routing via Relay** toggle; after approval every row turns Sent live with a progress bar |
| Launch my token $HERMIT on flap.sh | **Token launch:** Hermit fills in name, ticker, logo, supply, initial buy; connect flap.sh; **the flap.sh launch page opens inside Hermit**; one-tap Deploy → approval → token live (market cap, holders, contract), Share on X |
| Add always show Bollinger Bands on charts to your long-term memory | Saves to hermit.md, confirmation card |

**After any trade is approved** (news trades, perp tickets, opportunity trades), a **live candlestick card** posts into chat: entry, TP and SL lines, current price and PnL, ticking every second (simulated feed in the demo; real-time data in production).

**Websites inside Hermit:** checkout pages and launchpads (OpenAI billing, flap.sh) open in an in-app tab (`InAppTab` in `src/components/DemoFlows.jsx`) with a URL bar, so the user never leaves Hermit.

**Top stories (news):** every story carries a ready trade: side and leverage, suggested TP and SL with percentages, an **Edit** link that opens leverage/TP/SL fields inline, **Details**, and the trade button (e.g. *Long ETH 3x*, red for shorts) that opens the approval with the edited values.

**Attachments:** attach from Device, Photos, Hermit files or Drive. The file shows as a chip in the composer and in the sent bubble. The reply depends on the file type (invoice, CSV, PDF, chart image, code, doc).

**Memory:** saying "add … to your long-term memory" saves it to hermit.md and shows a card with View memory (opens Settings › Memory).

---

## 7. Projects (Claude-style)

- **List:** cards with gain and chat count. **New** opens a sheet (name, template chips, agent budget).
- **Project page:** like Claude, a **chat box sits above the tabs** ("Start a chat in …"); sending starts a chat inside the project. Tabs: Overview, Chats, Instructions, Files.
- **Overview:**
  - Stats: In operation, Cost, Gain (labelled by type: Sales, Yield, PnL, Claimed…), Net.
  - **Gains** card: total, gain chart and where it came from (e.g. Morpho vault, Aave, Pendle), all in one block.
  - **Costs** card: the project's monthly auto-payments (APIs, hosting, gas refills). Each item has an **on/off toggle**. Turning one off removes it from the total and runway right away, and the toast says how much it saves. Runway shows in months, or in days when short.
  - **Expected / mo:** forecast with its basis (e.g. "12 subscribers at $10"), the amount after costs, and "Updates daily, next in 21h". It is re-estimated every 24 hours.
- **Instructions:** project.md, editable, followed in every chat of that project.
- **Files:** open in the file viewer.

---

## 8. Automations (Claude-style)

- The page starts with a chat box: **"Describe an automation"** plus example chips.
- Sending opens an automation thread. Hermit replies with a **draft card**: When, Do, Spending, Approval (ask each time or runs on its own), with Edit and **Turn on**.
- After it's on, the thread is that automation's home: the original request, the confirmation, then **every run as a reply** (e.g. "Run Oct 20, 09:00: swapped 500 USDC for 0.143 ETH…").
- Change it by chatting: "make it every Friday at 6pm" → "Updated. Now runs every Friday 18:00." Also "pause", "resume", "run it now".
- The list shows each automation with its trigger, last run and an on/off toggle.

---

## 9. Trade

Tabs: **Positions, Markets, Strategies**.

- **Positions:** trading balance, unrealised, today, margin used. Open positions with entry, liquidation, who opened it (Agent/You) and when, and **TP/SL tags with % distance**, plus Edit (move stop to breakeven via approval). Open orders (Cancel). History.
- **Markets** (Hyperliquid-style terminal with AI; full width on desktop):
  - Type switch: Perps, Spot, Memes, Predictions.
  - **Market picker** with search (market, price, 24h, funding) and a stats bar: Mark, 24h, Volume, Open interest, Funding, Venue.
  - **Hermit actions** above the chart: *Draw key levels* (draws support/resistance), *Why is it moving?*, *Plan a trade* (fills the order form), *Size to 1% risk* (sets margin). The answer appears inline.
  - Candlestick chart with 15m/1H/4H/1D, TP/entry/SL lines, venue picker (Best price, Hyperliquid, Lighter, Aster, Paradex, Extended, trade.xyz).
  - Order book and recent trades.
  - Order form: Market/Limit, Long/Short, margin, leverage, take profit, stop loss, size, outcome at TP/SL, liquidation, risk as % of balance, a warning above 10x, and "Ask Hermit about HYPE".
  - Phone order: chart, order form, then order book.
  - Spot: token list (mini candles) and swap panel. Memes: safety tag, mini candles, Buy, holder map and Hermit's take. Predictions: Yes/No prices.
  - Explore more markets (stocks, gold, majors, memes, new tokens), all with logos.
- **Strategies:** running strategies with PnL and capital. A detail sheet shows stats, how it works, recent trades, Pause, and Open chat/project. **New** starts one in chat.

---

## 10. Earn

Tabs: **Positions, DeFi, Arbitrage, Airdrops, Reverse**.

- **Positions:** Earning, APY, Per month, **Earned (24h)**. Then everything already earning: DeFi deposits (Withdraw), arbitrage bots (open detail) and airdrop farms (open their chat, with wallets, funds in use and current loss).
- **DeFi:** filters (All, Stables, ETH, Low risk). Each opportunity row **expands**: 90-day chart, max drawdown, TVL, age, audits, fees, then **Deposit** and **Ask**.
- **Arbitrage:** deployed, profit, annualised, then live spreads that expand the same way.
- **Airdrops:** wallets running, funds, loss, estimated value, new campaigns (Farm), Hermit points tasks.
- **Reverse:** paste a vault or wallet, or pick a sample high-yield vault, and Hermit explains it in chat.
- **Explore more** (with search) under the discovery tabs.

---

## 11. Payments

Stablecoin-first: USDC on Base. Direct transfers to wallets/ENS/email, **x402** for paying APIs and agents per call, **Bridge** payouts to banks for fiat bills.

Tabs: **Schedule, Approvals (count badge), Transfer, Bills, APIs**.
- **Schedule:** next-7-days chart, pays-from card, live schedule. Each row opens a sheet: edit amount, pause/resume, pay now (approval), cancel.
- **Approvals:** payments above your auto-pay limit, each with Review.
- **Transfer:** to address, ENS, email, contacts or your own wallets, then Review.
- **Bills:** upload or forward invoices, upcoming bills paid from USDC to the payee's bank.
- **APIs:** your APIs with usage against monthly cap, plus a marketplace with categories and Buy (x402).

---

## 12. Wallets

- **Wallet picker = dropdown, grouped like Binance:** *All wallets*, then **Local wallets** ("Keys stay on this device": Main, Trading, Vault on Ledger) and **Privy wallets** ("Keyless, sign in with email or passkey": Solana, Airdrop farm). Each group has its own add action. Choosing local vs Privy happens here, **not in Settings**.
  - Add local: create, import with recovery phrase, connect hardware.
  - Create Privy: email, Google, Apple or passkey, then a confirm step (recovery, chains, agent spending).
- **Header (two cards of equal height on desktop):**
  - Left: Total balance, change, then four Binance-style round actions, evenly spaced and aligned with the balance: **Deposit** (or Add funds), **Send**, **Transfer**, **Bridge**.
  - Right: **Managed by agent** pie with **Assets** (USDC, ETH, SOL, HYPE, Memes, Other) or **Projects** (money inside each project plus "Not in a project"). Project rows open the project.
  - Under both: a short balance chart with 1W/1M/3M/1Y. On phones the pie card moves below the actions.
- **History icon** to the right of Total balance opens the full transaction history with filters (All, Sent, Received, Trades, APIs, Earn); each row opens its receipt.
- **Send (exchange-style):** From wallet, Network, address field with Paste and QR scan, a **whitelist** of saved, labelled, verified addresses, **Add address** (label, network, address, 24-hour security hold), and a **Whitelist only** switch that blocks sending anywhere else. Wrong-network and non-whitelisted addresses are flagged before Review.
- **All wallets tabs:** Tokens (opens a token sheet with candles, Send/Swap/Bridge/Earn), DApps, Gas, Activity, Accounts.
- **Gas:** every chain shows balance, a fill bar (red when low), "40 txs left", the dollar value, and two round buttons:
  - **Top up** (purple when low): pick $5/$10/$25 (shows how many transactions it buys), then **Swap from balance** (USDC/USDT already on that chain) or **From another wallet** (direct or bridged in 30s). Review → approval → the bar refills.
  - **Withdraw:** 25%, 50% or Max, then **Swap to USDC** or **Send to another wallet** → approval → the bar drops.
  - Auto top-up toggle refills any chain below 20 transactions.
- **Accounts:** X, Discord, Telegram with Connect/Disconnect.
- **One wallet:** balance and address (copy), Add funds/Send/Transfer/Bridge, then tabs for what that wallet funds: Projects, Trading, Payments, DeFi.

---

## 13. Other pages

- **Explore:** search, tabs **New, Trending, All**. All has one sideways-scrolling row of category chips. Each DApp card has a Claude-style button: **Connect**, or **Connected** (green check) that turns into **Disconnect** on hover. Includes the newest and most popular apps of the past year.
- **Connectors:** tabs **Apps, Buy APIs, Skills**, plus **+ MCP** to add a server. Turning on X, Discord, Telegram, Gmail, Calendar, GitHub runs a **demo sign-in**:
  - X / Discord / Google / GitHub: Hermit ⇄ app logos, "Hermit wants to access your account", the signed-in account, what it can access, what it can never do, Cancel / Authorize. Discord also picks a server. Then "Returning to Hermit…" and Connected.
  - Telegram: open @HermitBot, QR code, copyable code (HRM-4821), waits, then Connected.
- **Calendar (Notion Calendar-style):** week view (day view on phones) with a time grid, month view, board (To do / In progress / Done). Tap an empty slot to add. Colours per project, project filter chips. An item sheet has task/event, date, time, length, project, status, Open project, Ask, Delete, Save.
- **Files:** search, type chips, Record (live waveform) and Upload. **Clicking a file opens the file viewer** (below).
- **Settings:** tabs **Safety** (ask before spending over, daily limit, always-on protections), **Memory** (hermit.md editor), **Models** (on-device models), **Home** (show/hide the home cards).

### File viewer (Claude-style)
Opens over the main area (full screen on phones). Each open file is a **tab** with its own close button. Toolbar: zoom out, zoom %, zoom in, fit, download, Ask (sends the file to chat), close (Esc). ⌘+ / ⌘- zoom. The page is Notion-style: big title, properties (type, source, updated, size), then content by type: meeting notes with decisions and to-dos, an email thread with a suggested reply, docs with headings, research with a candle chart, a full CSV table, an invoice, code with line numbers, or an image. Changing page closes the viewer.

---

## 14. Assets

- `public/logos/`: token, chain, DApp, venue and app logos (CoinGecko, DefiLlama, Simple Icons). TSLA, NVDA, GOLD and HERM (a fictional scam token in the demo) are hand-made badges. To add one, drop the file in and map the lower-case name in `src/components/Mark.jsx`.
- `public/hermit-hero.png`: mascot on transparent background.
- `public/login-film.mp4` / `login-film.jpg`: graded, looping login film and its poster.

## 15. Mock data

All in `src/data.js`: user, wallets (with `type: 'local' | 'privy'`), holdings, gas per chain, DApps, earn opportunities and their details, perp/meme/prediction markets, strategies, airdrops, payments and schedule, bills, APIs, projects with costs (`projectBurn`), forecasts (`projectForecast`) and gain sources (`projectGains`), agent-managed assets by token and by project, to-dos, automations, files. Today in the demo is **Oct 26, 2026**.

## 16. Not in the demo (for the real build)

No real wallet, keys, chain calls, model, sign-in or payments. Logins, OAuth screens, Privy wallet creation, hazard scans and receipts are all visual stand-ins for the real flows described above.
