# Hermit AI insurance: deployments

## Mainnet (live)

| | |
|---|---|
| Contract | [`hermit-insurance.near`](https://nearblocks.io/address/hermit-insurance.near) |
| Wasm | `contracts/insurance/dist/insurance.wasm`, **195,455 bytes** |
| sha256 | `746b0b9947b2589be6c919f7854b8ec8ba0cbc5eb66a8a39074f28f84b300dc1` |
| On-chain code hash | `8qSxw5r3ZNX1NMZQAZ3Fjhs15FiitDucDkegt3oSpXJ8` (base58 of the sha256 above) |
| Token | USDC on NEAR, `17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1` |
| Price | 1 USDC for 30 days |
| Owner (decides claims) | `7a951014466f827af740f3bb45b9fb4772acb8753a8632ef2fb73a83a1a1e246`, a Hermit wallet's NEAR account |
| AI reviewer (writes verdicts, can't move money) | `b8794d334a4ee9a77f57e8cb1d3806f945476b40372308b42de3eeee2ef5f74e` |

| # | What | Tx |
|---|---|---|
| 1 | create `hermit-insurance.near` through the registrar | [`AgVXyZUZtt…`](https://nearblocks.io/txns/AgVXyZUZttdnBdcN5vnFmTpv56inCLLBmcahMqswYwMX) |
| 2 | deploy + `new` in one transaction | [`36VH2pTQfb…`](https://nearblocks.io/txns/36VH2pTQfbeTkpUYbmBg2igB8UY8PfT6QAEcEHR3T4ww) |
| 3 | register the contract with USDC (storage_deposit) | [`5YCQxQ3zfi…`](https://nearblocks.io/txns/5YCQxQ3zfih695i7V9yJ4C736mHoz13wJS2uNoBve8M4) |

`.venv/bin/python near/insurance.py info` reads the pool, members and claims.

## Testnet (rehearsal, same wasm)

`ins.hins1794555787.testnet` with a test token that requires registration like USDC (`ft.hins1794555787.testnet`):
cover bought for 1, pool funded with 50, a claim filed with evidence that hashes to its fingerprint, the AI review
written on chain, the owner approved 18, and the 18 arrived in the claimant's token balance. Final state: pool 33,
paid in 51, paid out 18, owed 0, claim status `paid`. `near/insurance.py --network testnet --contract ins.hins1794555787.testnet claims` shows it.
