# Hermit Black Box: deployments

## Mainnet (live)

| | |
|---|---|
| Contract | [`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near) |
| Wasm | `contracts/blackbox/dist/blackbox.wasm`, **163,578 bytes** |
| sha256 | `d90670f7fd19124d2ba19eb69440a5513908d2a5a1cad3542664ad54fe12c61a` |
| On-chain code hash | `FcBAhBovqfKHHKA3maMyV5C9DCNq3wKRmQzW9cFFW5H3` (base58 of the sha256 above) |
| Owner | `hermit-blackbox.near` itself; its full-access key is kept off the repository |
| Built with | rustc 1.86.0, `build.sh` = cargo build `--locked` + binaryen v119 `wasm-opt`, near-sdk 5.17.2 |

### What ran on mainnet

| # | What | Result | Tx |
|---|---|---|---|
| 1 | create `hermit-blackbox.near` through the registrar | ok | [`EJBJu7VeJk…`](https://nearblocks.io/txns/EJBJu7VeJkEMCUQuxEokf9U9k2eRZoEhwi9vDabh9w3h) |
| 2 | deploy + `new` in one transaction | ok | [`BuQyq9wUL5…`](https://nearblocks.io/txns/BuQyq9wUL5Csok5iVJkG6gnu3Y2ctWnvLfa4F5pjVJoJ) |
| 3 | publish Hermit 1.3 Lite | ok | [`GULCTTBEDR…`](https://nearblocks.io/txns/GULCTTBEDR3pnjNpLS5RZjkjFYH7TXnAQsLNTugumvv2) |
| 4 | publish Hermit 1.3 | ok | [`BmZzF1mk4A…`](https://nearblocks.io/txns/BmZzF1mk4A2VJxWAwFdbAYF4ksTfxZq14tGnJgn85QPp) |
| 5 | publish Hermit 1.2 | ok | [`4o5KxZRbUU…`](https://nearblocks.io/txns/4o5KxZRbUUxdW27ukZnR3Mu2gyzo8vo5VoeHmWagprcH) |
| 6 | publish Hermit 1.1 Lite | ok | [`Grimy2w9k6…`](https://nearblocks.io/txns/Grimy2w9k6K29rsifJ4oyZjccfiYaqBcVxLwZ6KS8reR) |
| 7 | a function-call key limited to `record` writes the first fingerprint (0.00018 NEAR of its allowance) | ok | [`GEh7vi8yjP…`](https://nearblocks.io/txns/GEh7vi8yjPsr7PBSoPmtUy2o3PwghX7MS1WgRzAHXiU) |
| 8 | the same key calls `set_owner` | refused by NEAR (`InvalidAccessKeyError`), owner unchanged | |

`python3 near/blackbox.py check` then prints `[PASS]` for all four models the app pins.

## Testnet (rehearsal)

`hbb1794552840.testnet`: the same wasm; four models published, `check` 4/4 PASS, one record, a republish refused.
