# iPhone app: road to TestFlight

The Mac app waits until the iPhone app is on TestFlight. Tick each item only after it's verified on a real iPhone or in
a signed build, not just in a snapshot.

## A. Accounts and signing (team)
- [ ] Mac build box reachable (`ssh mac`): plugged in, awake, tunnel up.
- [ ] App Store Connect API key with the **App Manager** role: Issuer ID, Key ID, `.p8` stored on the Mac only.
- [ ] Bundle ID `my.hermit.ios` registered on team 4G5YW2XP2B with these capabilities: Keychain Sharing, Increased Memory Limit.
- [ ] App record in App Store Connect: name (e.g. "Hermit: Private AI"), SKU, primary language, category Productivity.
- [ ] Apple Distribution certificate + App Store profile (automatic signing with the API key: `-allowProvisioningUpdates`).
- [ ] Internal testers added in App Store Connect (up to 100 team users, no Beta Review needed).

## B. App: real, no fake data
- [ ] Merge the four real-data branches (real-shell, real-pages, real-wallet, real-markets) and build for iOS.
- [ ] No seeded people, balances, threads, calendar items or stats anywhere; empty states instead.
- [ ] Controls that aren't wired yet are greyed out with a short "Soon".
- [ ] Onboarding asks only "What should Hermit call you?".

## C. App: iPhone-first
- [ ] Every tab laid out for a 390pt-wide screen: nothing cut off, no Mac-sized rows, safe areas respected.
- [ ] Sheets come from the bottom with detents; the keyboard never covers the composer.
- [ ] Dynamic Type up to XL doesn't break layouts; VoiceOver labels on icon buttons.
- [ ] Launch to first screen in under a second; scrolling smooth at 120 Hz on a ProMotion iPhone.
- [ ] No crash in a 15-minute session through every tab (Xcode Organizer / TestFlight crash logs clean).

## D. App: the core promise works
- [ ] Model download on first run: size shown first, progress, resumes after the app is backgrounded, Wi-Fi warning on cellular.
- [ ] Woof 2B chats in flight mode on a 6 GB+ iPhone; smaller phones get a clear "needs a newer iPhone" note.
- [ ] `com.apple.developer.kernel.increased-memory-limit` entitlement; the model unloads on memory warnings.
- [ ] Wallet: create / import and Face ID approval work; keys stay in the Keychain; mainnet sends stay off for the beta.

## E. App Store Connect paperwork
- [ ] App icon 1024 px, no alpha; launch screen.
- [ ] `PrivacyInfo.xcprivacy` (UserDefaults, file timestamp and disk space reasons; no tracking).
- [ ] `ITSAppUsesNonExemptEncryption` set (standard crypto for signing and auth: exempt, but the team confirms).
- [ ] Privacy policy URL (hermit.my/privacy) and support URL (hermit.my).
- [ ] Beta description, What to Test, feedback email (contact@hermit.my).
- [ ] Age rating questionnaire (unrestricted AI chat: likely 17+).
- [ ] Build number goes up on every upload (`CURRENT_PROJECT_VERSION`).

## F. Upload
- [ ] `scripts/release-ios.sh` on the Mac: archive, export with the App Store method, upload with the API key.
- [ ] Build processed in App Store Connect, assigned to the internal group, installed via the TestFlight app.

## Risks to decide before external testing (public link / waitlist)
- **Guideline 3.1.5(a):** apps that store crypto must come from a developer enrolled as an **organisation**. Team
  4G5YW2XP2B is an individual account, so external Beta Review may reject the wallet. Internal testing is fine.
- **"Uncensored" wording** in the beta description invites a stricter review; describe it as private, on-device AI.
