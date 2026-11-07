# Hermit iOS: 0 → 1 launch checklist

Goal: every button in the app does what it says, nothing looks unfinished, and the App Store build passes review.
Rule for the submitted build: **if a feature isn't working by submit day, it is hidden, not greyed out** (Apple rejects
"Coming soon" placeholders under 2.1 / 2.3.1). TESTFLIGHT.md covers the beta mechanics; this file covers the product.

Legend: [x] done · [~] in progress · [ ] to do · ⚠ review risk

## 0. Blockers outside the code (Apple account and legal)

- [ ] ⚠ **Organization developer account.** Guideline 3.1.5(i): crypto wallets must come from a developer enrolled as an
      organization. Ours is an individual account (Utsavraj Singh). Either enroll Hermit AI Labs as an organization
      (needs a legal entity + D-U-N-S number, about 1–2 weeks) or ask Apple to migrate the individual account to an
      organization. **Without this the App Store submission will be rejected, however good the app is.**
- [ ] ⚠ **Perps / futures (Hyperliquid, trade.xyz).** 3.1.5(iv) reserves futures trading for licensed firms. Wallets such
      as Phantom and MetaMask ship Hyperliquid perps as non-custodial front ends from organization accounts. We do the
      same: the user signs every order with their own key, we never hold funds, and the countries Hyperliquid blocks
      (US, Ontario and others) are blocked in the app too.
- [ ] ⚠ **Prediction markets (Polymarket).** Treated as real-money gaming in many countries. Ship behind a country check:
      off where Polymarket itself is geo-blocked; reviewers in the US see it disabled with a clear reason.
- [ ] Terms of Use page (hermit.my/terms): non-custodial, not financial advice, risk of loss, restricted countries.
- [ ] Age rating 17+ (unrestricted web access, real-money trading).
- [x] Privacy policy live at hermit.my/privacy (update when connectors land: Binance keys, MCP servers).
- [ ] App Privacy questionnaire in App Store Connect: "Data not collected" (true today; recheck after connectors).
- [ ] Export compliance: ITSAppUsesNonExemptEncryption=false is set; standard crypto only, exempt.

## 1. Look and feel (no white space, no cut text, every logo)

- [x] Sheets size to their content (Send, Receive, Create, Import, Pay, Schedule): no empty band under the buttons.
- [x] Earn chain tabs ("All chains, Ethereum, Base, …") scroll sideways on the phone.
- [x] Logos bundled for every Hyperliquid perp (235), trade.xyz stocks, spot tokens (426 total); commodities, indices and
      currencies get a drawn mark or flag. Remote lookup is the fallback for new listings.
- [x] Robinhood (chain and HOOD) logo; Solana uses the current mark.
- [ ] Earn → DeFi pools: protocol logos for every pool (DefiLlama icon + bundled fallback).
- [ ] Sweep every screen at iPhone SE, 16, 16 Pro Max and with large Dynamic Type: cut text, overflow, overlaps.
- [ ] Dark mode decision: either support it or force light everywhere (no half-dark sheets).
- [ ] Empty, loading and error states on every list (no blank screens with the network off).

## 2. Wallet (the base everything else signs with)

- [x] Create / import / back up / delete, Face ID unlock, Secure Enclave seal.
- [x] Send native + ERC-20 + SPL with review screen and hazard check; mainnet on.
- [ ] Generic contract call: approve + call with simulation and a readable review screen (needed by Earn, Swap, Bridge, HL deposit).
- [ ] EIP-712 typed-data signing with a readable review (needed by Hyperliquid orders, Polymarket orders, Permit2).
- [ ] Solana: sign and send arbitrary transactions (Jupiter swaps, Kamino deposits).
- [ ] Receive: QR + copy for every chain (verify Robinhood Chain, Monad).
- [ ] QR scanner for addresses (VisionKit DataScanner; camera usage string).
- [ ] Swap (EVM: 0x or LI.FI quotes; Solana: Jupiter). Fee disclosed on the review screen.
- [ ] Bridge (LI.FI / Across) between supported chains.
- [ ] Gas top-up: swap a little of a token into the native coin when the user has none.
- [ ] WalletConnect (Reown WalletKit): "Connect a dApp", session list, sign requests through the same review screen.
- [ ] Transaction history per wallet (explorer APIs), pending → confirmed states, local notifications.

## 3. Trade (Hyperliquid + trade.xyz)

- [x] Markets list, prices, charts, market picker sheet, Predictions tab removed.
- [ ] Deposit: USDC on Arbitrum → Hyperliquid bridge (one contract call), live balance on Hyperliquid.
- [ ] Withdraw: signed `withdraw3` action back to Arbitrum.
- [ ] Agent key: approve a Hyperliquid API wallet once (EIP-712), kept in the Keychain, so orders don't need Face ID each tap.
- [ ] Place / cancel orders: market and limit, long and short, leverage, TP/SL, reduce-only. Review screen shows size,
      liquidation price and fees.
- [ ] Positions tab: live positions, PnL, close, edit TP/SL. Open orders and fills.
- [ ] Spot buy/sell on Hyperliquid spot.
- [ ] Builder fee (optional revenue): disclosed in the review screen and terms.
- [ ] Restricted-country check before any order (device region + Hyperliquid's own error).

## 4. Earn

- [ ] DeFi Deposit: Aave v3 supply/withdraw (Ethereum, Base, Arbitrum), ERC-4626 vaults (Morpho, Euler), Kamino / Jupiter
      Lend on Solana. Each pool row → deposit sheet → approve + supply → position appears under Positions.
- [ ] Positions tab: real positions read from chain (aTokens, vault shares), with withdraw.
- [ ] Arbitrage / funding tab: either a working one-tap basis trade on Hyperliquid (spot long + perp short) or hide it.
- [ ] Airdrops / reverse tabs: read-only info is fine; remove any button that doesn't act.

## 5. Connectors and MCP

- [ ] MCP client in the app: add a remote MCP server by URL (streamable HTTP + OAuth or bearer token), list its tools,
      call them from chat and from a tool browser. Tokens kept in the Keychain.
- [ ] Binance: API key + secret (read-only by default, trade toggle), balances, spot orders through the same review screen.
- [ ] Polymarket: markets list, buy/sell outcome shares via the CLOB (EIP-712 signed orders, USDC on Polygon), country check.
- [ ] Calendar (done), Reminders, Contacts (permission prompts with usage strings).
- [ ] Gmail / Google Calendar / Notion / GitHub / X / Telegram / Discord: OAuth via ASWebAuthenticationSession, or their
      official MCP servers through the MCP client. Each one only when it works end to end; the rest are hidden.
- [ ] Buy APIs tab (paid APIs via x402): pay per call from the wallet with a review screen, or hide the tab.
- [ ] Skills: each listed skill either runs or is removed.

## 6. The AI (on-device)

- [x] Download in the background with Live Activity; chat offline.
- [ ] Tool calling: the on-device model can call wallet read-only tools, markets, calendar and MCP tools. Anything that
      moves money always stops at the review screen with Face ID; the AI can never sign by itself.
- [ ] Voice input (Speech framework, on-device) or remove the mic button.
- [ ] Files: recording or remove the button.
- [ ] Memory notes editable in Settings (done) and used in replies (done).

## 7. Payments page

- [ ] Transfer / schedule / payees: scheduled payments run (local notification + approve on tap; iOS can't sign in the background).
- [ ] Pay now, Buy: working or hidden.

## 8. App Store submission package

- [ ] Screenshots: 6.9" (1320×2868) and 6.5" sets, 5–10 each, real app content.
- [ ] App name, subtitle, promotional text, description, keywords, support URL (hermit.my/support), marketing URL.
- [ ] Review notes: demo steps, a funded test wallet phrase on testnet (and mainnet dust if trading is on), why the wallet
      is non-custodial, which countries trading is blocked in.
- [ ] Demo video link for reviewers showing trade and deposit flows (they can't fund a wallet themselves).
- [ ] Sign in with Apple not required (no accounts). No IAP needed (no digital goods sold).
- [ ] Crash-free run on a real device: cold launch offline, low storage during download, Face ID cancelled, network drop mid-send.
- [ ] Run the app-store-review checklist (safaiyeh/app-store-review-skill) on the final build.

## Order of work

1. Look and feel (section 1); ship a TestFlight build.
2. Wallet base: contract calls, EIP-712, Solana arbitrary tx, QR scanner (section 2).
3. Hyperliquid deposit + orders + positions (section 3). Earn deposits on Aave / ERC-4626 (section 4).
4. Swap, bridge, WalletConnect (section 2).
5. MCP client, Binance, Polymarket (section 5); AI tool calling (section 6).
6. Hide whatever isn't finished; submission package (section 8); organization account must be in place by then.
