# Hermit AI insurance

Live on NEAR mainnet as [`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near). An opt-in pool
that pays you back when the AI made a mistake that cost you money.

## How it works

1. **Cover.** In the app it unlocks once the Black Box is on, because a claim needs its records. Send 1 USDC on NEAR with
   `ft_transfer_call(msg: "cover")` and you're covered for 30 days. Every cent goes
   into the pool. Anyone can add to the pool with `msg: "fund"`.
2. **Claim.** While covered, file a claim with the [Black Box](../blackbox) fingerprint of the move and the text behind
   it, plus a 0.05 NEAR deposit for storage. The contract checks `sha256(evidence) == fingerprint`, so the evidence is
   exactly what your device recorded. One claim per record.
3. **AI review.** The reviewer account checks the record is on `hermit-blackbox.near` under your account and compares
   what you asked for with what the AI prepared. Its verdict and reason go on chain. It can't move money.
4. **Decision.** The owner approves or rejects in the Hermit app, with a reason that goes on chain.
5. **Payout.** The approved amount is sent in USDC from the pool. There's no cap per claim: if the pool is short, the
   rest is paid as it refills (`settle`, which anyone can call).

Only an approved claim can take money out of the pool. There is no admin withdraw.

## Methods

| Method | Who | What |
|---|---|---|
| `ft_on_transfer` (`msg` "cover" or "fund") | USDC contract | buy cover, or add to the pool |
| `file_claim({fp, evidence, loss, note})` | covered account, 0.05 NEAR | open a claim |
| `ai_review({id, verdict, reason})` | reviewer | approve, reject or unsure, with a reason |
| `decide({id, approve, award, reason})` | owner, 1 yocto | decide; approving pays from the pool |
| `settle({id})` | anyone | pay what an approved claim is still owed |
| `set_owner`, `set_reviewer`, `set_price` | owner, 1 yocto | admin, never touches the pool |
| `info`, `cover_of`, `claims`, `get_claim` | view | read everything |

## Build and test

Same toolchain as Hermit Guard and Black Box (Rust 1.86.0, binaryen v119).

```sh
cargo test                                   # 20 unit tests
CARGO=cargo WASM_OPT=wasm-opt ./build.sh     # dist/insurance.wasm
cd sandbox-tests && cargo test               # real wasm, a real NEP-141 token, real accounts
```

The sandbox story: buy cover, fund the pool, a stranger's claim refused, a claim with matching evidence filed, the
reviewer can't decide and a stranger can't review, the AI review and the owner's approval, 18 tokens land in the
claimant's balance, and a second claim on the same record is refused.

Mainnet and testnet records: [DEPLOYMENTS.md](DEPLOYMENTS.md). Tools: `near/insurance.py`.
