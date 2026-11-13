# Hermit Terms and Conditions

_Last updated November 13, 2026_

> **In short:** Hermit is a self-custody wallet with an AI assistant. You hold your keys, and nothing moves until you approve it. The assistant can be wrong, so check every review before you approve. Crypto is risky and transactions can't be undone. Hermit charges no fees, gives no financial advice and never holds your money.

## 1. Agreeing to these terms

These terms are between you and Hermit ("Hermit", "we", "us"). They cover the Hermit apps for iPhone and Mac, hermit.my, docs.hermit.my, the Hermit models and the Hermit Black Box, Hermit AI insurance and Hermit Guard contracts (together, "Hermit"). By downloading or using Hermit you agree to these terms and to our [Privacy Policy](https://hermit.my/privacy). If you don't agree, don't use Hermit. If you got Hermit from the App Store or TestFlight, Apple's terms also apply to that download.

## 2. What Hermit is

Hermit is software that runs on your device. It creates and stores wallet keys on your device, shows balances and prices, and has an AI assistant that can answer questions and prepare actions such as sends, swaps, trades, staking and payments for you to review.

Hermit is not a bank, broker, exchange, custodian, money transmitter or investment adviser. We never hold, control or have access to your keys or funds, and we can't move, freeze, reverse or recover them.

## 3. Who can use it

You must be at least 18, or the age of majority where you live, and able to agree to these terms. You may not use Hermit if you are on a sanctions list, or in a place where using it, or the services it connects to, is against the law. Some features, such as perpetual futures, may not be available or legal where you are; it's your job to check.

## 4. Your keys and recovery phrase

- Your 12-word recovery phrase and keys are made on your device and sealed by its security chip. They are never sent to us.
- You are the only one who can recover your wallets. Write the recovery phrase down and keep it safe. If you lose your device and your phrase, your funds are gone, and we can't help get them back.
- Anyone with your phrase, or with your unlocked device and its passcode, can take your funds. Never share the phrase. Hermit will never ask you for it.
- You're responsible for the security of your device, its passcode and its software updates.

## 5. The AI assistant

- The assistant is a language model. It can misread you, get facts, prices or numbers wrong, or suggest something that doesn't suit you, even when it sounds sure.
- It only prepares actions. It can't sign or send anything by itself. Every money action opens a review screen that shows exactly what will happen, and it only goes ahead when you approve it.
- Where Hermit changes an action so the venue accepts it, such as raising a size to a venue's minimum or moving a stop to the right side of the price, the review tells you. Read it before you approve.
- Answers, summaries and suggestions are for information only. Don't rely on them alone for decisions about money, health, law or anything important.
- Automations and scheduled items you create run only as described in the app. Unless the app says a payment runs on its own, such as a Hermit Guard standing order you set up, a scheduled item is a reminder that you approve when it comes up.

## 6. Approvals and transactions

- When you approve with Face ID, Touch ID or your passcode, you authorise that transaction. You are responsible for checking the review first: the recipient, network, token, amount, price, fees and any changes Hermit shows.
- Blockchain transactions are final. They can't be cancelled or reversed by us or, usually, by anyone.
- Sending to a wrong address or the wrong network, or approving a malicious site or contract, can lose your funds for good.
- Spending limits, hazard scans and other safety checks in Hermit reduce risk. They don't remove it, and they don't catch everything.
- Network fees, slippage, price moves and delays are set by blockchains and other services, not by us. A quote can change or expire before it's filled.

## 7. Third-party services

To do what you ask, Hermit connects to services run by others, including blockchains and their nodes, NEAR Intents (1Click) and its solvers, Relay, NEAR AI Cloud, NVIDIA's attestation service, Hyperliquid, Aave, Solana exchanges and token sources, NEAR staking pools, price and data providers, Hugging Face for model downloads, and sites you open in the in-app browser. Those services aren't ours. We don't control them, don't promise they'll be available or accurate, and aren't responsible for their actions, outages, fees or losses. Their own terms and privacy policies apply when you use them.

## 8. NEAR features

- **Swaps and bridges.** NEAR Intents and Relay quotes are filled by third parties. Hermit checks a quote's signature and shows it to you, but delivery depends on those services. If a swap fails, refunds go to the refund address in the quote, under those services' rules.
- **Staking.** Staked NEAR is delegated to a validator's staking pool you choose. Rewards aren't guaranteed and can change. Unstaked NEAR is locked for about four epochs (roughly 28 hours) before you can withdraw it. Validators can perform badly or go offline.
- **Hermit Black Box.** Hermit Black Box is a smart contract on NEAR mainnet ([hermit-blackbox.near](https://nearblocks.io/address/hermit-blackbox.near)). It is optional and off until you turn it on. When it's on, each AI move you approve leaves a fingerprint on the blockchain: a salted hash and a short kind, never your chat, amounts or addresses. You keep the text behind each fingerprint on your device. Records on the blockchain can't be edited or removed.
- **Hermit AI insurance.** Hermit AI insurance is a smart contract on NEAR mainnet ([hermit-insurance.near](https://nearblocks.io/address/hermit-insurance.near)). It is optional, and it unlocks once the Black Box is on, because a claim needs its records. 1 USDC buys 30 days of cover, and all of it goes into a public pool. If the AI prepared something that cost you money, you can file a claim with its Black Box record. An AI reviewer writes a verdict, and Hermit decides each claim at its discretion. An approved claim is paid in USDC from the pool, as far as the pool allows. Cover is not a guarantee of payment. The evidence text you file with a claim is public on the blockchain. Smart contracts can have bugs, and you use them at your own risk.
- **Hermit Guard.** Hermit Guard is a smart contract on NEAR mainnet ([hermit-guard.near](https://nearblocks.io/address/hermit-guard.near)). Funds you put in a Guard vault are held by the contract under the rules you set, not by us. You can withdraw them with your own key. Anyone can trigger a standing order once it's due, and it pays only what your rules allow. Smart contracts can have bugs, and blockchain upgrades or network problems can affect them. The contract's code is public in our repository, and you use it at your own risk.

## 9. Trading, perps and yield

- Perpetual futures and leverage carry high risk. A position can be liquidated, and you can lose everything you put in, quickly.
- Orders, stops and take profits are placed on the venue you choose, such as Hyperliquid. They can fill at a different price, partly fill or not fill at all. Venues set their own minimums, margin rules and fees.
- Yields, lending and liquidity products, such as Aave or pools shown in Earn, can lose value through smart-contract failures, depegs, bad debt or market moves. Rates shown are past or current rates, not promises.
- Tokens, especially new or small ones, can be scams, lose all their value, or be impossible to sell. Hermit showing a token doesn't mean we've checked or endorse it.

## 10. Private Cloud

Private Cloud is optional. When you use it, your message goes to NEAR AI Cloud, run by a third party, after your device checks the enclave's proof. Hermit gives you some free Private Cloud messages a day through a shared key. We can change or end this allowance at any time. If you add your own NEAR AI key, your use is under your agreement with that provider.

## 11. Fees

Hermit doesn't charge you a fee. AI insurance is optional and separate: what you pay for cover goes into the claims pool. You pay network fees, and any fees the services you use charge, such as swap spreads, venue trading fees or validator commission. They are shown in the review when they're known.

## 12. No advice

Nothing in Hermit, from the app, the assistant, the site or the docs, is financial, investment, legal or tax advice, or a recommendation to buy, sell or hold anything. Make your own decisions, and talk to a qualified professional if you need advice. You are responsible for any taxes on your activity.

## 13. Risks

By using Hermit you accept the risks of crypto assets, including: prices can swing hard and go to zero; software, smart contracts, bridges and blockchains can fail or be attacked; networks can fork, stall or change; laws can change and limit what you can do; and any loss of your keys, phrase or device can be permanent.

## 14. Acceptable use

Don't use Hermit to break the law, including sanctions, money-laundering, fraud and market-manipulation laws; to harm, scam or impersonate anyone; to attack, overload or misuse Hermit or the services it connects to, including the shared Private Cloud key; or to build an unsafe copy of Hermit that you present as ours.

## 15. Beta builds and updates

TestFlight builds and some features are early versions. They may change, break or be removed without notice. We may release updates to fix problems or improve Hermit; some may be needed to keep using it. We may change or stop any part of Hermit at any time. Because your wallets live on your device and your recovery phrase works in other wallets that support it, you can always reach your funds outside Hermit.

## 16. Open source and the Hermit name

Hermit's app code is published under the MIT License, and that license governs your use of the code. The Hermit models have their own license on their model pages. The Hermit name, logo and look are ours; don't use them in a way that suggests something is made or approved by us when it isn't. What you write and the files you add stay yours, and they stay on your device unless you send them somewhere.

## 17. No warranty

Hermit is provided "as is" and "as available", without warranties of any kind, express or implied, including fitness for a particular purpose, accuracy, availability and non-infringement, to the fullest extent the law allows. We don't promise that Hermit will be error-free, secure or uninterrupted, or that the assistant's output will be right.

## 18. Limitation of liability

To the fullest extent the law allows, Hermit and its team aren't liable for any indirect, incidental, special, consequential or punitive damages, or for any loss of funds, tokens, profits, data or opportunity, arising from your use of Hermit, the assistant's output, transactions you approve, third-party services, smart contracts or blockchains. Our total liability for any claim about Hermit is limited to US$100. Some places don't allow these limits, so some of them may not apply to you.

## 19. Indemnity

You agree to cover Hermit and its team against claims, losses and costs, including reasonable legal fees, that come from your breaking these terms, breaking the law or misusing Hermit.

## 20. Ending use

You can stop using Hermit at any time by deleting the app. Your funds stay on their blockchains, and your recovery phrase still opens them in other wallets. We may limit or end access to services we run, such as the shared Private Cloud key, if you break these terms. Sections 4 to 13 and 17 to 22 continue to apply after you stop.

## 21. Changes

We may update these terms. When we do, we'll change the date at the top of this page, and for important changes we'll tell you in the app or on hermit.my. If you keep using Hermit after a change, you accept the new terms.

## 22. General

These terms and the Privacy Policy are the whole agreement between you and us about Hermit. If part of them can't be enforced, the rest still applies. If we don't enforce something right away, we haven't given up the right to. You can't transfer these terms to someone else; we may transfer them if Hermit changes hands. If a dispute comes up, write to us first and we'll try to solve it in good faith. Nothing here takes away rights you have by law as a consumer.

## 23. Contact

Hermit, [contact@hermit.my](mailto:contact@hermit.my)

Also at https://hermit.my/terms
