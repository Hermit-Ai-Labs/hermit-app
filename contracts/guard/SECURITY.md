# Hermit Guard: security notes

Status: **not audited, not fuzzed, not on mainnet.** Everything below says what a test proves and what is only reasoned about.
Tests: unit tests in `src/tests.rs` (mocked chain, 40 tests), end-to-end tests in `sandbox-tests/tests/story.rs` (local nearcore
sandbox, real wasm, real access keys, 12 tests), and one recorded run on testnet (`DEPLOYMENTS.md`, re-checked on chain by
`near/guard-demo.py`). CI runs unit and sandbox tests on every push: `.github/workflows/guard.yml`.

## What it protects, from whom

* Assets: tokens in vaults. The contract account holds them all, so one bug can touch every user.
* A **pocket key** holder (an app, a script, an agent, or whoever steals that key) must not be able to do more than the pocket allows.
* A **stranger** must not be able to spend from or withdraw from someone else's vault.
* A **token contract** on the list is trusted; one not on the list must not be able to credit anything.
* The **contract deployer** is a trust question: see "Not sure" below.
* Out of scope: a stolen full-access key of the owner (the owner can do everything, by design), a bug in NEAR itself, front-end bugs.

## Invariants and what proves them

| # | Invariant | Where it is enforced | Proven by |
|---|---|---|---|
| 1 | Only the owner's full-access path can reach owner methods. Each owner method is `#[payable]` and starts with `assert_one_yocto()`; a function-call key cannot attach a deposit. | `owner_entry()` in `lib.rs` | unit `every_owner_method_needs_exactly_one_yocto` (every owner method, deposits 0, 2 and 1 NEAR, called with a key). Sandbox `a_pocket_key_cannot_reach_owner_methods`: the real runtime rejects the pocket key (method list, and "deposit with function-call key"), and a deliberately misconfigured key that lists the owner methods is refused by the contract ("exactly 1 yocto"). Testnet tx 15 and the two runtime refusals. |
| 2 | A pocket key never moves more than `per_payment_cap` in one payment and `daily_cap` in one window. | `check_payment`, `charge_window` | unit `spend_over_per_payment_cap_is_refused`, `daily_cap_holds_and_resets_after_the_window`, `order_uses_the_pockets_daily_cap`; sandbox `pocket_key_spends_inside_its_rules_and_is_refused_outside`; testnet txs 10 and 13. **Caveat:** windows are fixed, so across a window edge a key can spend up to 2x the cap in a short time. Approved requests deliberately bypass the caps (the owner decided). |
| 3 | A pocket key can pay only to allowed recipients, only its own token, only while not paused, not expired and the vault not frozen. | `check_payment`, `spend` | unit `spend_to_non_allowed_recipient_is_refused`, `spend_after_expiry_paused_or_frozen_is_refused`, `spend_refusals`; sandbox `expired_paused_and_frozen_are_refused`; testnet txs 11 and 27. |
| 4 | Only the owner can withdraw, and withdraw pays only the owner's own account. Not blocked by freeze. | `withdraw` | unit `withdraw_works_also_when_frozen`, `stranger_cannot_touch_another_vault`; sandbox `strangers_cannot_move_or_read_into_another_vault`, `expired_paused_and_frozen_are_refused`; testnet tx 28. |
| 5 | Nobody but the listed paths can move funds: owner withdraw/approve/close, pocket-key spend, due standing orders. | whole API surface (no admin, no upgrade, no `unsafe`, no raw promises other than `start_payout`) | by reading `lib.rs` (one function, `start_payout`, creates a payout promise) and the tests above. **No test enumerates the ABI**; this one rests on code review. |
| 6 | A key is looked up by (caller account, signer key) and the call must be direct (`signer == predecessor`). Another account's pocket key does nothing. | `pocket_entry` | unit `only_a_pocket_key_called_directly_can_spend`. |
| 7 | State per vault is bounded (8 pockets, 20 orders, 10 requests, 50 receipts, 20 recipients, names 24 bytes, texts 140 bytes, at most 8 tokens) and prepaid: the 0.5 NEAR deposit covers the largest possible vault. | constants at the top of `lib.rs`; `create_*`, `request`, `validate_config` | unit `worst_case_vault_fits_the_deposit` (builds a maximal vault, 41,061 bytes against 50,000 prepaid, and checks the price per byte), `ninth_pocket_is_refused`, `pocket_input_limits`, `order_limits`, `eleventh_request_refused_and_old_ones_are_cleaned`, `receipts_keep_the_last_fifty_in_order`; sandbox `storage_limits_hold_for_real` (9th pocket and 21st order refused on a real chain). Not tested on chain: a vault with all 10 requests and 50 receipts at maximum length. |
| 8 | A payout is paid at most once: state is reduced before the transfer; a failure restores balance, pocket window and order schedule exactly once (`on_payout` is private and runs once per receipt). | `start_payout`, `on_payout` | unit `failed_spend_is_put_back`, `failed_order_payment_restores_schedule_and_count`, `failed_ft_withdraw_and_approval_are_put_back`, `settled_spend_stays_spent_and_a_new_window_is_not_touched`; sandbox `test_token_spend_and_failed_transfer_is_restored` and `worst_case_vault_callback_and_methods_fit_their_gas` (unregistered recipient, also on a vault filled to every limit; balance, daily total and order schedule all checked); testnet tx 30. Sandbox `strangers_...` proves `on_payout` and `new` refuse outsiders. |
| 9 | A vault cannot be closed while payouts are in flight or balances are not zero, so a late refund always has a vault to return to. | `close_vault`, `pending_out` | unit `close_vault_refunds_and_keeps_the_owner_list_consistent`; sandbox `close_vault_refunds_the_storage_deposit`. |
| 10 | A standing order pays only when due, only once per period, never in a burst, and obeys the pocket's rules. | `check_order`, `execute_order` | unit `order_not_due_is_refused_and_changes_nothing`, `due_order_pays_for_anyone_once_per_period`, `missed_periods_do_not_pile_up`, `remaining_count_runs_down_and_deletes_the_order`, six `blocked_order_*` tests (state unchanged), `due_orders_pages_across_owners`; sandbox `standing_orders_run_when_due_for_anyone_once_per_period`; testnet txs 24, 25, 33 (keeper). |
| 11 | Only allowlisted token contracts can credit a vault, and only to a sender who has a vault. | `ft_on_transfer` | unit `ft_on_transfer_credits_only_allowlisted_tokens_with_a_vault`; sandbox `strangers_...`. |
| 12 | Requests: stored not paid, expire after 7 days, approve needs the owner, frozen blocks approval. | `request`, `approve` | unit `request_then_approve_pays`, `request_reject_frozen_expiry_and_limits`; sandbox `request_then_owner_approves`; testnet txs 20 and 21. |
| 13 | The wasm loads on nearcore. | `build.sh` | The sandbox tests and the testnet deployment run the final file (sha256 `dd0ea418...1b64`). Plain `cargo build` output does **not** load (we saw `PrepareError(Deserialization)`); `build.sh` rewrites it with binaryen v119 and validates it as MVP wasm. |
| 14 | The final build is reproducible. | `build.sh` (path remapping, pinned toolchain, `--locked`) | Checked once: two copies of the source in different directories on the same machine gave the same sha256. Not checked across machines or in CI. |
| 15 | Solvency: the contract holds at least what it owes. Everything that came in and was not paid out covers the NEAR in vaults plus the storage the vaults use; for the test token the contract's balance equals the sum of vault balances exactly. | whole payout path | sandbox `contract_stays_solvent_and_holds_exactly_the_tokens_it_owes`, after a story with a successful and a failed (non-existent account) native payout, a successful and a failed (unregistered) token payout, orders, withdrawals and a closed vault. The run printed: balance grew 4.3011 NEAR, vault owed 3.8, storage grew 0.0183 (surplus 0.4828 = the unused part of the 0.5 deposit plus 1-yocto leftovers). One scenario, not a proof. |
| 16 | The set of exported methods is pinned: no fund-moving method can be added unnoticed. | `sandbox-tests/exports.txt` | sandbox `exported_methods_are_pinned` parses the export section of the built wasm and fails on any difference with the checked-in list (32 functions; `contract_source_metadata` is near-sdk's own view). The only methods that can send funds out are `spend`, `withdraw`, `approve`, `execute_order` (and `close_vault`, which refunds the storage deposit to the owner). |
| 17 | The settlement callback and every payout method fit their gas, also on a vault filled to every limit. | `CALLBACK_GAS`, `MIN_GAS_FOR_PAYOUT` | sandbox `worst_case_vault_callback_and_methods_fit_their_gas`, numbers below. |

## Gas, measured on a vault filled to every limit

Sandbox test `worst_case_vault_callback_and_methods_fit_their_gas`: 8 pockets (24-byte names, 20 recipients each), 20 orders and 10 requests and
50 receipts with 140-byte texts, all 8 token balances used (NEAR + 7 test tokens). Each call below was sent with only 125 TGas attached.
"Burnt" is the gas the receipt actually used.

| call | entry method | `on_payout` |
|---|---|---|
| (b) spend NEAR, ok | 7.1 TGas | 6.2 TGas |
| (a) spend token, transfer FAILS, everything restored | 7.3 TGas | 6.3 TGas |
| (c) execute_order, transfer FAILS, schedule and count restored | 7.2 TGas | 6.4 TGas |
| (d) withdraw token, ok | 7.1 TGas | 6.2 TGas |
| (d) withdraw NEAR, ok | 7.0 TGas | 6.2 TGas |
| (e) approve a request, ok | 7.0 TGas | 6.1 TGas |

Worst `on_payout`: **6.4 TGas** against 40 TGas of static gas (6.2x; the test fails if it is below 2x). Worst entry method: 7.3 TGas against a
budget of 125 - 30 - 40 = 55. The numbers vary by about 0.1 TGas between runs. 40 TGas turned out generous; it was not lowered.
Not measured: the same calls on a mainnet token (see below).

## Design choices that matter for safety

* Every state change happens before the cross-contract call (checks, then effects, then interaction). The vault is loaded as a copy,
  changed, and saved once at the end of a method, so no half-written state is visible to another call.
* `execute_order`, `spend`, `approve` and `withdraw` refuse to run unless 120 TGas are left after the call is decoded (attach 125 at least, tools
  attach 150): 30 for the token transfer, 40 for the settlement callback, the rest for the method. If the gas were ever short the promise
  creation fails and the whole call reverts, so nothing is lost either way.
* `ft_transfer` is called with 1 yocto and 30 TGas; the callback gets 40 TGas. Native payouts are plain transfers. Both have a callback, because a native
  transfer to a named account that does not exist also fails.
* Arithmetic is checked (`overflow-checks = true`, `checked_add`, `saturating_sub` where a wrap would be harmless).
* Rule violations panic, so a refused spend leaves no receipt. The receipt list only holds payments that were sent.
* A receipt's `ok` flag is true when the payout is sent and turns false if the transfer later fails. Between the two, `pending_out` in the vault view is above 0.

## NOT sure, not tested, or accepted

1. **Deployer trust.** The code has no upgrade path, but while the contract account still has a full-access key its holder can redeploy
   and take everything. Deleting the keys after the mainnet smoke test removes that and also makes bugs unfixable. Not decided; not done.
2. **Not audited, no fuzzing, no property tests, no formal checks.** The invariants above are tested with chosen examples.
3. **Callback gas** is now measured at the worst case (table above), with a 6x margin. What is still not covered: a token contract whose
   `ft_transfer` burns more than 30 TGas (it would fail, and the contract would restore the money; the payout simply could not be made).
4. **The real mainnet tokens were not exercised.** Their ids were checked on mainnet RPC (USDC `17208628...133a1`, USDT `usdt.tether-token.near`) and
   their `storage_balance_bounds` read (0.00125 NEAR each); all payout tests used our test token, which now behaves like them (registration is required,
   payment to an unregistered account fails and is restored). A real token that charges fees, has hooks, or behaves differently on `ft_transfer_call` could still surprise us. The guard
   must be registered with each token before use (`guard.py deploy` does it); recipients and owners must be registered too.
5. **Fixed window.** Up to twice the daily cap can move around a window edge (documented, not a bug, but a surprise for users).
6. **Approvals ignore the caps** (that is their purpose) and do not count toward the daily total.
7. **Order lost on a failed final run if its slot was reused.** If the last run of a counted order fails and the owner has meanwhile used
   the freed slot (20 orders again) or removed the pocket, the order is not restored. The money always is.
8. **The contract's NEAR balance is not checked against its liabilities by any test.** The accounting (sum of vault balances plus
   storage deposits stays below the contract balance) follows from the code, but no test asserts it. Each owner call also leaves
   1 yocto in the contract that nobody can take out. Anyone can also send NEAR to the contract by plain transfer; it is not credited to anyone and cannot be recovered.
9. **Spam.** Anyone can open a vault for 0.5 NEAR. This grows the owner list but `due_orders` pages 20 owners at a time, so reads stay cheap.
10. **Public RPC and time.** `due_orders` and the "not due yet" check use block time; a view call uses the latest block, which can differ by a block from the one that runs the transaction (a keeper may send a call that the chain then refuses, and nothing is lost but gas).
11. **A pocket key's gas allowance** is set by the owner when adding the key (default 1 NEAR in `guard.py`). When it runs out the key stops; the owner re-adds it. Not a funds risk.
12. **Python tools.** `guard.py` is verified against near-api-js transaction bytes, hash and signature (`--selftest`), and the AddKey and DeleteKey layouts were proven by real use on testnet.
    The key files it writes are mode 600 and never printed. It has no hardware-wallet or Ledger support, and no check that `--contract` is the contract you think it is.
13. **Toolchain trust.** The shipped wasm is the output of rustc 1.86.0 then binaryen v119 `wasm-opt -Oz --signext-lowering`. A bug in either is not covered by our tests beyond the behaviours exercised.
14. **No test on mainnet and none planned before review.**
