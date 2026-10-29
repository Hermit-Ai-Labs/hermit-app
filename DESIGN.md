# How Hermit should feel

The bar is super premium and classy: it should feel like an app Apple made. The web demo
(hermit-demo.vercel.app, repo hermit-demo, README sections 1–2) is the visual spec; this file is how we
build it natively.

## Motion and scrolling
- **Never fake scrolling.** Use `ScrollView` / `List` as they are. They are UIScrollView / NSScrollView, with
  Apple's own deceleration (0.998), rubber band (0.55) and spring back. No custom drag-to-scroll, no
  scroll hijacking, no gesture recognisers fighting the scroll view.
- **Springs only.** Every animation uses the system springs: `.smooth` (default), `.snappy` (taps, toggles,
  selection), `.bouncy` only for playful moments (a success tick). No linear or easeIn curves for UI motion.
- **Fast and quiet.** Taps answer in under 100 ms. Transitions take 0.2–0.35 s. Animate opacity, scale and
  offset; never animate layout jumps you can avoid.
- Pressed buttons scale to about 0.97 (see `PressStyle`, `ChipStyle`, `BlackButton`).
- Use `.contentTransition(.numericText())` for changing numbers, `matchedGeometryEffect` for selection
  indicators, and `scrollTransition` sparingly for subtle depth in carousels.
- Lists of many rows use lazy stacks. Everything stays at 120 Hz on ProMotion.

## Look
- Tokens in `Theme` (Theme.swift). Pure white page, `Theme.subtle` panels, 1 px `Theme.border` lines.
- **Purple (`Theme.accent`) is only for key actions**: Approve, Ask, New chat, primary brand buttons. Everything
  else is black, greys and white. Gains `Theme.green`, losses `Theme.red`.
- UI text is SF Pro (the system font). `Font.serif` (Newsreader) only for big greetings and headlines.
- Cards: `.card()` (14 pt radius, border, white). Sheets 20 pt radius.
- **Real logos only** via `LogoMark("name")`. Never a letter placeholder if a logo exists.
- **Price charts are always candlesticks** (`Candles`). Balance, PnL and APY can be `LineChart`.
- **One tab row per page** (`Page` + `PageTabs`). Secondary choices are a `Segmented` control or a menu.
- Copy is short and plain. No `·` (middle dot) separators. No marketing filler.
- Every button does something: opens a sheet, changes state, shows a `model.toast(...)`, or posts to chat.
- Every money move goes through `model.approval = Approval(...)` (the hazard-scan sheet with Touch ID / Face ID).

## Platforms
- Mac: sidebar layout, hover states, keyboard shortcuts, right-click menus where natural.
- iPhone: bottom tab bar (Chat, Trade, Earn, Payments, Wallets), sheets from the bottom, nothing ever scrolls
  sideways except a single tab row. Comfortable 44 pt tap targets.
