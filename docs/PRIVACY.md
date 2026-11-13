# Hermit Privacy Policy

_Last updated November 13, 2026_

> **In short:** Hermit has no account and no server that stores your data. Your chats, memory, files and wallet keys stay on your device. We don't track you, sell anything about you, or show ads. Your use of Hermit is also covered by our [Terms](https://hermit.my/terms).

## What stays on your device

- The name you give Hermit, your chats, your memory notes and the files you add.
- The AI model. Once downloaded, it runs on your device and answers without the internet.
- Wallet keys. They are created on your device, sealed with the device's security chip and unlocked with Face ID, Touch ID or your passcode. Hermit can't see or recover them.
- Calendar events, only if you allow calendar access. Hermit reads them on your device.
- Contacts, automations, spending limits, settings and saved balances you see while offline.

## When Hermit uses the internet

Hermit connects only to do what you ask. It sends no personal information beyond what each request needs:

- **Downloading the AI model** from Hugging Face.
- **Prices and market data** from public sources such as Hyperliquid, CoinGecko and DefiLlama, and coin and company logos from public image sources.
- **Wallet balances and transactions** through public blockchain nodes (RPCs). A transaction you approve is broadcast to its blockchain, where it is public by nature, as with any wallet.
- **Private Cloud, if you use it.** It is optional and off unless you turn it on or pick it. Your message and the chat's context are then sent to NEAR AI Cloud (cloud-api.near.ai), which runs the model inside a hardware-secured enclave (Intel TDX with NVIDIA confidential GPUs). Before anything is sent, the app verifies the enclave's attestation on your device; for the GPU check it sends only the GPU's attestation evidence, never your message or key, to NVIDIA's attestation service. Hermit doesn't store these chats. A shared key built into the app is used by default, with a small daily limit counted on your device; you can add your own NEAR AI key, which is stored in your device's Keychain.
- **Swaps and bridges through Relay** (relay.link), which the Swap screen asks alongside NEAR Intents for a better price. It gets the same details: tokens, amount and your addresses.
- **NEAR staking and Hermit Guard.** Staking, unstaking and Hermit Guard vaults are transactions on NEAR mainnet that you approve. Hermit Guard is a public smart contract (hermit-guard.near): the rules, payments and receipts you put in it, including a reason you type, are public on the blockchain. A small helper we run calls standing orders when they're due; it only sees what is already public on chain.
- **Trading on Hyperliquid**, if you use it. Orders, deposits and withdrawals you approve are signed on your device and sent to Hyperliquid with your address.
- **Websites you open in the in-app browser**, and the apps you connect your wallet to there. They see your public address once you connect.
- **Swaps through NEAR Intents** (the 1Click API at 1click.chaindefuser.com). To get a quote or make a swap, Hermit sends the token pair, the amount, and your refund and receiving addresses. Nothing moves until you approve the swap with Face ID, Touch ID or your passcode. You can also pick NEAR Intents' confidential swap option.

Spending limits you set are kept and checked on your device.

Those services may log ordinary connection details, such as your IP address, under their own privacy policies.

## What we collect

Nothing from the app. If you join the waitlist on hermit.my, we keep the email and answers you give us there, only to contact you about Hermit. Write to us and we'll delete them.

## Analytics and crash reports

The app contains no analytics or tracking. If you test Hermit through TestFlight and choose to send feedback or crash reports, Apple shares those with us under Apple's terms.

## Children

Hermit is for people 18 and over, and we don't knowingly collect anything from children.

## Your rights

Because the app keeps your data on your device, you can see, change or delete it yourself: delete a chat, edit memory in Settings, or delete the app to remove everything (your wallets stay on their blockchains, reachable with your recovery phrase). For anything we hold, like a waitlist email, write to us to see, fix or delete it. We don't sell or share personal information.

## Security

Keys are sealed by your device's security chip and unlocked only while signing. Connections use HTTPS. No system is perfectly secure, so keep your device updated, use a passcode and keep your recovery phrase offline.

## Changes

If this policy changes, we'll update this page and the date above.

## Contact

Hermit, [contact@hermit.my](mailto:contact@hermit.my)

Also at https://hermit.my/privacy
