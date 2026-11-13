# Hermit Black Box

Our second contract on NEAR mainnet: [`hermit-blackbox.near`](https://nearblocks.io/address/hermit-blackbox.near).
Two public records that nobody, us included, can quietly rewrite.

## 1. Model registry

For every Hermit model we ship: the Hugging Face revision, the SHA-256 of the weights, a digest of every file the app pins,
the size and the held-out test scores.

- **Append-only.** An id can be published once. Its hashes can never change; a bad release can only be marked revoked,
  with a reason, and the old entry stays readable.
- **Checked by the app.** Settings > Models compares the model the app pins with the registry (`check_model`).
- **Checked by anyone.** `python3 near/blackbox.py check` recomputes every digest from
  `Packages/HermitKit/Sources/HermitModel/ModelPins.swift` and asks the chain.

The pin digest is SHA-256 over one line per pinned file, sorted by path: `path<TAB>size<TAB>sha256<LF>`. Swift
(`BlackBox.pinDigest`) and Python (`near/blackbox.py`) compute the same value; `BlackBoxTests` pins it.

## 2. Flight recorder

When you approve a move the assistant prepared, the app can write a fingerprint of that decision: SHA-256 over what the
review showed, what happened, the model, the time and a random salt from the device.

- **Only the hash goes on chain.** Never the chat, the amounts or the addresses. The salt makes it impossible to guess.
- **The device keeps the text behind each hash**, so you can later prove exactly what the AI proposed and what you
  approved, and anyone can check it against the chain.
- **No storage, gas only.** Each record is an event log (`EVENT_JSON`, standard `hermit-blackbox`), not stored data; the
  contract keeps only a counter. A record burns about 2 Tgas, roughly 0.0002 NEAR.
- **Off by default.** Settings > Safety > Black box adds one function-call key to your NEAR account that can only call
  `record` on this contract, with a 0.05 NEAR gas allowance (about 270 records). One approval to turn it on; after that,
  records need none. It can't move money: owner methods need a 1-yoctoNEAR deposit, which a function-call key can't attach.

## Methods

| Method | Who | What |
|---|---|---|
| `publish_model({model})` | owner, 1 yocto | add a model; refused if the id exists |
| `revoke_model({id, reason})` | owner, 1 yocto | mark revoked; hashes stay |
| `set_owner({owner})` | owner, 1 yocto | hand over control |
| `record({fp, kind, model?})` | anyone | log one fingerprint under the caller's account |
| `get_model`, `models`, `check_model`, `info` | view | read the registry |

## Build and test

Same toolchain as Hermit Guard: Rust 1.86.0 (pinned in `rust-toolchain.toml`), binaryen v119 `wasm-opt`.

```sh
cargo test                                   # 17 unit tests
CARGO=cargo WASM_OPT=wasm-opt ./build.sh     # dist/blackbox.wasm
cd sandbox-tests && cargo test               # the real wasm in a local nearcore, with real access keys
```

The sandbox story: the owner publishes, a republish and a stranger are refused, `check_model` passes, a function-call key
limited to `record` writes a fingerprint, that key can't publish, change the owner or move NEAR, 5 more records leave
storage unchanged, and a revoked model fails `check_model`.

See [DEPLOYMENTS.md](DEPLOYMENTS.md) for the live contract and its mainnet test.
