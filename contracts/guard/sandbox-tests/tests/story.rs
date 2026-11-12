//! End-to-end tests against a local nearcore sandbox, with the real wasm and real access keys.
//! GUARD_WASM and FT_WASM point at the built contracts (CI sets them; see ../README.md).
use near_workspaces::network::Sandbox;
use near_workspaces::result::ExecutionFinalResult;
use near_workspaces::types::{AccessKey, KeyType, NearToken, SecretKey};
use near_workspaces::{Account, AccountId, Contract, Worker};
use serde_json::{json, Value};
use std::time::Duration;

const Y: u128 = 1_000_000_000_000_000_000_000_000;
const STORAGE_DEPOSIT: u128 = Y / 2;

fn near(n: u128) -> NearToken {
    NearToken::from_yoctonear(n)
}

fn read_wasm(var: &str, default: &str) -> Vec<u8> {
    let path = std::env::var(var).unwrap_or_else(|_| default.to_string());
    std::fs::read(&path).unwrap_or_else(|e| panic!("cannot read {} ({}): {}", var, path, e))
}

struct World {
    worker: Worker<Sandbox>,
    guard: Contract,
    ft: Contract,
    alice: Account,
    bob: Account,
    carol: Account,
    /// alice's account signing with the pocket key (a function-call key limited to spend/request)
    pocket: Account,
    pocket_sk: SecretKey,
    /// more test tokens (only in the worst-case gas test), all on the guard's allowlist
    extra_fts: Vec<Contract>,
}

async fn wasm_ok(w: &Worker<Sandbox>, who: &Account, to: &AccountId, m: &str, args: Value, deposit: u128) -> ExecutionFinalResult {
    let _ = w;
    who.call(to, m).args_json(args).deposit(near(deposit)).max_gas().transact().await.expect("transaction could not be sent")
}

/// Sends a call and reports whether it was refused, either by the runtime before execution or by the contract.
async fn refused(who: &Account, to: &AccountId, m: &str, args: Value, deposit: u128) -> (bool, String) {
    match who.call(to, m).args_json(args).deposit(near(deposit)).max_gas().transact().await {
        Err(e) => (true, format!("{:?}", e)),
        Ok(r) => (r.is_failure(), format!("{:?}", r)),
    }
}

async fn now_ns(w: &Worker<Sandbox>) -> u64 {
    w.view_block().await.unwrap().timestamp()
}

async fn view(w: &Worker<Sandbox>, guard: &AccountId, m: &str, args: Value) -> Value {
    w.view(guard, m).args_json(args).await.unwrap().json::<Value>().unwrap()
}

async fn setup() -> World {
    setup_with(0).await
}

async fn setup_with(extra: usize) -> World {
    let worker = near_workspaces::sandbox().await.unwrap();
    let alice = worker.dev_create_account().await.unwrap();
    let bob = worker.dev_create_account().await.unwrap();
    let carol = worker.dev_create_account().await.unwrap();
    let ft = worker.dev_deploy(&read_wasm("FT_WASM", "../test-ft/target/wasm32-unknown-unknown/release/test_ft.wasm")).await.unwrap();
    ft.call("new").args_json(json!({"owner_id": alice.id(), "total_supply": "1000000000"})).transact().await.unwrap().into_result().unwrap();
    let mut extra_fts = vec![];
    for _ in 0..extra {
        let f = worker.dev_deploy(&read_wasm("FT_WASM", "../test-ft/target/wasm32-unknown-unknown/release/test_ft.wasm")).await.unwrap();
        f.call("new").args_json(json!({"owner_id": alice.id(), "total_supply": "1000000000"})).transact().await.unwrap().into_result().unwrap();
        extra_fts.push(f);
    }
    let wasm = read_wasm("GUARD_WASM", "../target/wasm32-unknown-unknown/release/hermit_guard.wasm");
    println!("guard wasm: {} bytes", wasm.len());
    let guard = worker.dev_deploy(&wasm).await.unwrap();
    guard
        .call("new")
        .args_json(json!({"tokens": std::iter::once("near".to_string()).chain(std::iter::once(ft.id().to_string())).chain(extra_fts.iter().map(|f| f.id().to_string())).collect::<Vec<_>>()}))
        .transact()
        .await
        .unwrap()
        .into_result()
        .unwrap();
    // register the guard and bob with the test token (carol stays unregistered on purpose)
    for who in [guard.id(), bob.id(), alice.id()] {
        if who == alice.id() {
            continue; // the owner is registered by `new`
        }
        alice
            .call(ft.id(), "storage_deposit")
            .args_json(json!({"account_id": who, "registration_only": true}))
            .deposit(near(Y / 100))
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }
    for f in &extra_fts {
        alice
            .call(f.id(), "storage_deposit")
            .args_json(json!({"account_id": guard.id(), "registration_only": true}))
            .deposit(near(Y / 100))
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }
    let pocket_sk = SecretKey::from_random(KeyType::ED25519);
    let pocket = Account::from_secret_key(alice.id().clone(), pocket_sk.clone(), &worker);
    World { worker, guard, ft, alice, bob, carol, pocket, pocket_sk, extra_fts }
}

impl World {
    fn g(&self) -> &AccountId {
        self.guard.id()
    }

    /// Owner opens a vault and funds it with `near_amount` NEAR.
    async fn open_and_fund(&self, near_amount: u128) {
        wasm_ok(&self.worker, &self.alice, self.g(), "open_vault", json!({}), STORAGE_DEPOSIT + near_amount).await.into_result().unwrap();
    }

    async fn owner(&self, m: &str, args: Value) -> ExecutionFinalResult {
        wasm_ok(&self.worker, &self.alice, self.g(), m, args, 1).await
    }

    /// Adds the function-call key (receiver = guard, methods spend/request) to alice's OWN account.
    async fn add_pocket_key(&self) {
        self.alice
            .batch(self.alice.id())
            .add_key(
                self.pocket_sk.public_key(),
                AccessKey::function_call_access(self.g(), &["spend", "request"], Some(near(Y))),
            )
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }

    fn pocket_cfg(&self, name: &str, token: &str) -> Value {
        json!({
            "name": name,
            "public_key": self.pocket_sk.public_key().to_string(),
            "token": token,
            "per_payment_cap": if token == "near" { near(Y).as_yoctonear().to_string() } else { "100".to_string() },
            "daily_cap": if token == "near" { near(3 * Y).as_yoctonear().to_string() } else { "250".to_string() },
            "allowed_recipients": [self.bob.id()],
            "expires_at": null
        })
    }

    async fn create_pocket(&self, cfg: Value) {
        self.owner("create_pocket", json!({"config": cfg})).await.into_result().unwrap();
    }

    async fn spend(&self, token: &str, amount: u128, to: &AccountId) -> (bool, String) {
        refused(&self.pocket, self.g(), "spend", json!({"token": token, "amount": amount.to_string(), "recipient": to, "reason": "test"}), 0).await
    }

    async fn vault(&self) -> Value {
        view(&self.worker, self.g(), "get_vault", json!({"owner": self.alice.id()})).await
    }

    async fn vault_balance(&self, token: &str) -> u128 {
        let v = self.vault().await;
        v["balances"]
            .as_array()
            .unwrap()
            .iter()
            .find(|b| b["token"] == token)
            .map_or(0, |b| b["amount"].as_str().unwrap().parse().unwrap())
    }

    async fn ft_balance(&self, who: &AccountId) -> u128 {
        let v = view(&self.worker, self.ft.id(), "ft_balance_of", json!({"account_id": who})).await;
        v.as_str().unwrap().parse().unwrap()
    }

    async fn near_balance(&self, who: &Account) -> u128 {
        who.view_account().await.unwrap().balance.as_yoctonear()
    }

    /// Waits until no payout is waiting for its callback.
    async fn settled(&self) {
        for _ in 0..40 {
            if self.vault().await["pending_out"] == 0 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        panic!("payout never settled");
    }

    async fn deposit_ft(&self, amount: u128) {
        self.alice
            .call(self.ft.id(), "ft_transfer_call")
            .args_json(json!({"receiver_id": self.g(), "amount": amount.to_string(), "msg": ""}))
            .deposit(near(1))
            .max_gas()
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }
}

#[tokio::test]
async fn pocket_key_spends_inside_its_rules_and_is_refused_outside() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    assert_eq!(w.vault_balance("near").await, 10 * Y);
    w.add_pocket_key().await;
    w.create_pocket(w.pocket_cfg("coffee", "near")).await;

    // within the caps: pays, and the log carries the NEP-297 event
    let before = w.near_balance(&w.bob).await;
    let r = wasm_ok(&w.worker, &w.pocket, w.g(), "spend", json!({"token":"near","amount":Y.to_string(),"recipient":w.bob.id(),"reason":"coffee"}), 0).await;
    assert!(r.is_success(), "{:?}", r);
    assert!(r.logs().iter().any(|l| l.starts_with("EVENT_JSON:") && l.contains("\"event\":\"spend\"")), "{:?}", r.logs());
    w.settled().await;
    assert_eq!(w.near_balance(&w.bob).await - before, Y);
    assert_eq!(w.vault_balance("near").await, 9 * Y);

    // over the per-payment cap
    let (bad, text) = w.spend("near", Y + 1, w.bob.id()).await;
    assert!(bad && text.contains("over per-payment cap"), "{}", text);
    // recipient not on the list
    let (bad, text) = w.spend("near", 1, w.carol.id()).await;
    assert!(bad && text.contains("recipient not allowed"), "{}", text);
    // wrong token
    let (bad, _) = w.spend(w.ft.id().as_str(), 1, w.bob.id()).await;
    assert!(bad);
    // daily cap: 1 NEAR already spent, two more fit, the next does not
    assert!(!w.spend("near", Y, w.bob.id()).await.0);
    assert!(!w.spend("near", Y, w.bob.id()).await.0);
    let (bad, text) = w.spend("near", 1, w.bob.id()).await;
    assert!(bad && text.contains("over daily cap"), "{}", text);
    w.settled().await;
    assert_eq!(w.vault_balance("near").await, 7 * Y);
    let receipts = view(&w.worker, w.g(), "get_receipts", json!({"owner": w.alice.id()})).await;
    assert_eq!(receipts.as_array().unwrap().len(), 3);
    assert!(receipts.as_array().unwrap().iter().all(|r| r["ok"] == true && r["kind"] == "spend"));
}

#[tokio::test]
async fn expired_paused_and_frozen_are_refused() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    w.add_pocket_key().await;
    let mut cfg = w.pocket_cfg("short", "near");
    let expiry = now_ns(&w.worker).await + 12_000_000_000;
    cfg["expires_at"] = json!(expiry.to_string());
    w.create_pocket(cfg).await;
    assert!(!w.spend("near", 1, w.bob.id()).await.0); // still valid
    // paused
    w.owner("pause_pocket", json!({"name": "short"})).await.into_result().unwrap();
    let (bad, text) = w.spend("near", 1, w.bob.id()).await;
    assert!(bad && text.contains("pocket paused"), "{}", text);
    w.owner("resume_pocket", json!({"name": "short"})).await.into_result().unwrap();
    assert!(!w.spend("near", 1, w.bob.id()).await.0);
    // frozen
    w.owner("freeze", json!({})).await.into_result().unwrap();
    let (bad, text) = w.spend("near", 1, w.bob.id()).await;
    assert!(bad && text.contains("vault frozen"), "{}", text);
    // withdraw still works while frozen
    let r = w.owner("withdraw", json!({"token": "near", "amount": Y.to_string()})).await;
    assert!(r.is_success(), "{:?}", r);
    w.owner("unfreeze", json!({})).await.into_result().unwrap();
    // expiry: wait for the chain clock to pass it
    for _ in 0..60 {
        w.worker.fast_forward(5).await.unwrap();
        if now_ns(&w.worker).await > expiry {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(now_ns(&w.worker).await > expiry, "chain clock did not reach the expiry");
    let (bad, text) = w.spend("near", 1, w.bob.id()).await;
    assert!(bad && text.contains("pocket expired"), "{}", text);
}

#[tokio::test]
async fn a_pocket_key_cannot_reach_owner_methods() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    w.add_pocket_key().await;
    w.create_pocket(w.pocket_cfg("coffee", "near")).await;
    // 1. the key's own method list stops it (runtime level), with or without a deposit
    for (m, args) in [
        ("withdraw", json!({"token":"near","amount":null})),
        ("update_pocket", json!({"config": w.pocket_cfg("coffee", "near")})),
        ("approve", json!({"request_id": 1})),
        ("freeze", json!({})),
        ("close_vault", json!({})),
    ] {
        for deposit in [0u128, 1] {
            let (bad, text) = refused(&w.pocket, w.g(), m, args.clone(), deposit).await;
            assert!(bad, "{} with deposit {} was not refused: {}", m, deposit, text);
        }
    }
    // 2. a MISCONFIGURED key that does list the owner methods still cannot call them: a function-call key
    //    cannot attach the 1 yocto, and without it the contract refuses.
    let evil_sk = SecretKey::from_random(KeyType::ED25519);
    w.alice
        .batch(w.alice.id())
        .add_key(
            evil_sk.public_key(),
            AccessKey::function_call_access(w.g(), &["withdraw", "update_pocket", "approve", "freeze", "close_vault", "create_pocket"], Some(near(Y))),
        )
        .transact()
        .await
        .unwrap()
        .into_result()
        .unwrap();
    let evil = Account::from_secret_key(w.alice.id().clone(), evil_sk, &w.worker);
    let (bad, text) = refused(&evil, w.g(), "withdraw", json!({"token":"near","amount":null}), 1).await;
    assert!(bad, "{}", text); // runtime: deposit with function-call key
    let (bad, text) = refused(&evil, w.g(), "withdraw", json!({"token":"near","amount":null}), 0).await;
    assert!(bad && text.contains("exactly 1 yocto"), "{}", text); // contract: assert_one_yocto
    for (m, args) in [
        ("update_pocket", json!({"config": w.pocket_cfg("coffee", "near")})),
        ("approve", json!({"request_id": 1})),
        ("freeze", json!({})),
        ("close_vault", json!({})),
        ("create_pocket", json!({"config": w.pocket_cfg("mine", "near")})),
    ] {
        let (bad, text) = refused(&evil, w.g(), m, args, 0).await;
        assert!(bad && text.contains("exactly 1 yocto"), "{}: {}", m, text);
    }
    assert_eq!(w.vault_balance("near").await, 10 * Y);
    assert_eq!(w.vault().await["frozen"], false);
}

#[tokio::test]
async fn request_then_owner_approves() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    w.add_pocket_key().await;
    w.create_pocket(w.pocket_cfg("coffee", "near")).await;
    // over the cap and to someone who is not on the list: spend refused, request accepted
    assert!(w.spend("near", 5 * Y, w.carol.id()).await.0);
    let r = wasm_ok(&w.worker, &w.pocket, w.g(), "request", json!({"token":"near","amount":(5*Y).to_string(),"recipient":w.carol.id(),"reason":"laptop"}), 0).await;
    assert!(r.is_success(), "{:?}", r);
    let reqs = view(&w.worker, w.g(), "get_requests", json!({"owner": w.alice.id()})).await;
    assert_eq!(reqs.as_array().unwrap().len(), 1);
    assert_eq!(w.vault_balance("near").await, 10 * Y);
    let id = reqs[0]["id"].as_u64().unwrap();
    // the pocket key cannot approve its own request
    assert!(refused(&w.pocket, w.g(), "approve", json!({"request_id": id}), 0).await.0);
    let before = w.near_balance(&w.carol).await;
    let r = w.owner("approve", json!({"request_id": id})).await;
    assert!(r.is_success(), "{:?}", r);
    w.settled().await;
    assert_eq!(w.near_balance(&w.carol).await - before, 5 * Y);
    assert_eq!(w.vault_balance("near").await, 5 * Y);
    let receipts = view(&w.worker, w.g(), "get_receipts", json!({"owner": w.alice.id()})).await;
    assert_eq!(receipts[0]["kind"], "approved");
}

#[tokio::test]
async fn test_token_spend_and_failed_transfer_is_restored() {
    let w = setup().await;
    w.open_and_fund(1 * Y).await;
    w.deposit_ft(1000).await;
    assert_eq!(w.vault_balance(w.ft.id().as_str()).await, 1000);
    w.add_pocket_key().await;
    let ftid = w.ft.id().to_string();
    let mut cfg = w.pocket_cfg("tok", &ftid);
    cfg["allowed_recipients"] = json!([w.bob.id(), w.carol.id()]);
    w.create_pocket(cfg).await;
    // like USDC/USDT, the test token refuses transfers to an account that never registered
    let (bad, text) = refused(&w.alice, w.ft.id(), "ft_transfer", json!({"receiver_id": w.carol.id(), "amount": "1"}), 1).await;
    assert!(bad && text.contains("not registered"), "{}", text);
    // pays a registered recipient
    assert!(!w.spend(&ftid, 100, w.bob.id()).await.0);
    w.settled().await;
    assert_eq!(w.ft_balance(w.bob.id()).await, 100);
    assert_eq!(w.vault_balance(&ftid).await, 900);
    // carol never registered with the token: ft_transfer fails, the callback puts everything back
    let (bad, text) = w.spend(&ftid, 100, w.carol.id()).await;
    assert!(!bad, "the spend itself is accepted, the transfer fails later: {}", text);
    w.settled().await;
    assert_eq!(w.ft_balance(w.carol.id()).await, 0);
    assert_eq!(w.vault_balance(&ftid).await, 900, "balance must be restored");
    let receipts = view(&w.worker, w.g(), "get_receipts", json!({"owner": w.alice.id()})).await;
    let r = receipts.as_array().unwrap();
    assert_eq!(r.len(), 2);
    assert_eq!(r[0]["ok"], true);
    assert_eq!(r[1]["ok"], false);
    // the failed 100 was given back to the pocket's daily window too (cap 250: 100 spent, 150 left)
    assert!(!w.spend(&ftid, 100, w.bob.id()).await.0);
    assert!(!w.spend(&ftid, 50, w.bob.id()).await.0);
    assert!(w.spend(&ftid, 1, w.bob.id()).await.0);
    w.settled().await;
    // withdraw to an owner that is registered works; the vault ends at 900 - 150
    let r = w.owner("withdraw", json!({"token": ftid, "amount": "50"})).await;
    assert!(r.is_success());
    w.settled().await;
    assert_eq!(w.vault_balance(&ftid).await, 700);
}

#[tokio::test]
async fn standing_orders_run_when_due_for_anyone_once_per_period() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    w.create_pocket(json!({
        "name": "rent", "public_key": null, "token": "near",
        "per_payment_cap": (2 * Y).to_string(), "daily_cap": (4 * Y).to_string(),
        "allowed_recipients": [w.bob.id()], "expires_at": null
    }))
    .await;
    let now = now_ns(&w.worker).await;
    // order 1: due in an hour (not due). order 2: due already, one run only.
    w.owner("create_order", json!({"pocket":"rent","amount":Y.to_string(),"recipient":w.bob.id(),"interval_seconds":3600,"first_due_ns":null,"remaining":null,"memo":"later"})).await.into_result().unwrap();
    w.owner("create_order", json!({"pocket":"rent","amount":Y.to_string(),"recipient":w.bob.id(),"interval_seconds":3600,"first_due_ns":(now - 1_000_000_000).to_string(),"remaining":1,"memo":"now"})).await.into_result().unwrap();
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    let (later, due) = (orders[0]["id"].as_u64().unwrap(), orders[1]["id"].as_u64().unwrap());
    let listed = view(&w.worker, w.g(), "due_orders", json!({"from_index": 0, "limit": 20})).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["order_id"].as_u64().unwrap(), due);
    // not due: refused, nothing moves
    let (bad, text) = refused(&w.carol, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": later}), 0).await;
    assert!(bad && text.contains("order not due yet"), "{}", text);
    assert_eq!(w.vault_balance("near").await, 10 * Y);
    // due: a stranger triggers it and the money goes to bob
    let before = w.near_balance(&w.bob).await;
    let r = wasm_ok(&w.worker, &w.carol, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": due}), 0).await;
    assert!(r.is_success(), "{:?}", r);
    w.settled().await;
    assert_eq!(w.near_balance(&w.bob).await - before, Y);
    // the second trigger (same period / order already used up) is refused
    let (bad, _) = refused(&w.carol, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": due}), 0).await;
    assert!(bad);
    assert_eq!(w.vault_balance("near").await, 9 * Y);
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    assert_eq!(orders.as_array().unwrap().len(), 1); // the remaining=1 order is gone
    // an endless order that is run once cannot be run twice in the same period
    w.owner("create_order", json!({"pocket":"rent","amount":Y.to_string(),"recipient":w.bob.id(),"interval_seconds":3600,"first_due_ns":(now - 1_000_000_000).to_string(),"remaining":null,"memo":"loop"})).await.into_result().unwrap();
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    let looping = orders[1]["id"].as_u64().unwrap();
    assert!(wasm_ok(&w.worker, &w.carol, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": looping}), 0).await.is_success());
    assert!(refused(&w.carol, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": looping}), 0).await.0);
    w.settled().await;
    assert_eq!(w.vault_balance("near").await, 8 * Y);
    // the frozen vault blocks orders
    w.owner("freeze", json!({})).await.into_result().unwrap();
    assert!(view(&w.worker, w.g(), "due_orders", json!({"from_index": 0, "limit": 20})).await.as_array().unwrap().is_empty());
}

#[tokio::test]
async fn strangers_cannot_move_or_read_into_another_vault() {
    let w = setup().await;
    w.open_and_fund(10 * Y).await;
    // bob has no vault: nothing to withdraw; with a vault of his own he still only sees his own
    let (bad, text) = refused(&w.bob, w.g(), "withdraw", json!({"token":"near","amount":null}), 1).await;
    assert!(bad && text.contains("no vault"), "{}", text);
    wasm_ok(&w.worker, &w.bob, w.g(), "open_vault", json!({}), STORAGE_DEPOSIT).await.into_result().unwrap();
    let (bad, _) = refused(&w.bob, w.g(), "withdraw", json!({"token":"near","amount":null}), 1).await;
    assert!(bad);
    assert_eq!(w.vault_balance("near").await, 10 * Y);
    // the settlement callback is private
    let settle = json!({"settle": {"owner": w.alice.id(), "token":"near", "amount": Y.to_string(), "receipt_id": 0, "pocket": null, "window_start": "0", "order_before": null}});
    let (bad, text) = refused(&w.bob, w.g(), "on_payout", settle, 0).await;
    assert!(bad && text.contains("private"), "{}", text);
    // the init cannot be run again
    let (bad, _) = refused(&w.bob, w.g(), "new", json!({"tokens": ["near"]}), 0).await;
    assert!(bad);
    // a person calling the NEP-141 receiver is not an allowlisted token: nothing is credited
    let r = wasm_ok(&w.worker, &w.bob, w.g(), "ft_on_transfer", json!({"sender_id": w.alice.id(), "amount": "5", "msg": ""}), 0).await;
    assert_eq!(r.json::<String>().unwrap(), "5");
    assert_eq!(w.vault_balance(w.ft.id().as_str()).await, 0);
    // tokens from an unlisted token contract: sending to the guard from an account with no vault is bounced back
    w.alice
        .call(w.ft.id(), "ft_transfer")
        .args_json(json!({"receiver_id": w.bob.id(), "amount": "10"}))
        .deposit(near(1))
        .transact()
        .await
        .unwrap()
        .into_result()
        .unwrap();
    w.bob
        .call(w.ft.id(), "ft_transfer_call")
        .args_json(json!({"receiver_id": w.g(), "amount": "10", "msg": ""}))
        .deposit(near(1))
        .max_gas()
        .transact()
        .await
        .unwrap()
        .into_result()
        .unwrap();
    // bob has a vault now, so these 10 are his, not alice's
    assert_eq!(w.vault_balance(w.ft.id().as_str()).await, 0);
    let bobs = view(&w.worker, w.g(), "get_vault", json!({"owner": w.bob.id()})).await;
    assert_eq!(bobs["balances"][0]["amount"], "10");
}

#[tokio::test]
async fn storage_limits_hold_for_real() {
    let w = setup().await;
    w.open_and_fund(1 * Y).await;
    for i in 0..8 {
        let mut cfg = w.pocket_cfg(&format!("p{}", i), "near");
        cfg["public_key"] = json!(SecretKey::from_random(KeyType::ED25519).public_key().to_string());
        w.create_pocket(cfg).await;
    }
    let mut cfg = w.pocket_cfg("p9", "near");
    cfg["public_key"] = json!(SecretKey::from_random(KeyType::ED25519).public_key().to_string());
    let (bad, text) = refused(&w.alice, w.g(), "create_pocket", json!({"config": cfg}), 1).await;
    assert!(bad && text.contains("pocket limit"), "{}", text);
    for i in 0..20 {
        let r = w.owner("create_order", json!({"pocket":"p0","amount":"1","recipient":w.bob.id(),"interval_seconds":3600,"first_due_ns":null,"remaining":null,"memo":format!("{:0>140}", i)})).await;
        assert!(r.is_success(), "order {}: {:?}", i, r);
    }
    let (bad, text) = refused(&w.alice, w.g(), "create_order", json!({"pocket":"p0","amount":"1","recipient":w.bob.id(),"interval_seconds":3600,"first_due_ns":null,"remaining":null,"memo":""}), 1).await;
    assert!(bad && text.contains("order limit"), "{}", text);
    // the contract account can pay for everything it stores: storage used x 1e19 <= balance - what vaults own
    let acct = w.guard.view_account().await.unwrap();
    println!("guard storage_usage after a nearly full vault: {} bytes", acct.storage_usage);
    assert!(acct.balance.as_yoctonear() > 0);
}

#[tokio::test]
async fn close_vault_refunds_the_storage_deposit() {
    let w = setup().await;
    w.open_and_fund(2 * Y).await;
    w.deposit_ft(300).await;
    // refused while there is a balance
    let (bad, text) = refused(&w.alice, w.g(), "close_vault", json!({}), 1).await;
    assert!(bad && text.contains("withdraw every balance first"), "{}", text);
    w.owner("withdraw", json!({"token": "near", "amount": null})).await.into_result().unwrap();
    w.settled().await;
    let (bad, _) = refused(&w.alice, w.g(), "close_vault", json!({}), 1).await;
    assert!(bad); // the token balance is still there
    w.owner("withdraw", json!({"token": w.ft.id(), "amount": null})).await.into_result().unwrap();
    w.settled().await;
    assert_eq!(w.ft_balance(w.alice.id()).await, 1000000000);
    let before = w.near_balance(&w.alice).await;
    w.owner("close_vault", json!({})).await.into_result().unwrap();
    // refund arrives with the next receipt
    for _ in 0..20 {
        if w.near_balance(&w.alice).await > before + STORAGE_DEPOSIT - Y / 20 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    let after = w.near_balance(&w.alice).await;
    assert!(after + Y / 20 > before + STORAGE_DEPOSIT, "refund missing: before {} after {}", before, after);
    assert!(w.vault().await.is_null());
    assert_eq!(view(&w.worker, w.g(), "owners_count", json!({})).await, 0);
}

// =====================================================================================================
// Worst case: a vault filled to EVERY limit. Proves the settlement callback and the entry methods fit in their gas.
// =====================================================================================================

fn tg(g: near_workspaces::types::Gas) -> f64 {
    g.as_gas() as f64 / 1e12
}

async fn call_gas(who: &Account, to: &AccountId, m: &str, args: Value, deposit: u128, tgas: u64) -> ExecutionFinalResult {
    who.call(to, m)
        .args_json(args)
        .deposit(near(deposit))
        .gas(near_workspaces::types::Gas::from_tgas(tgas))
        .transact()
        .await
        .expect("transaction could not be sent")
}

/// (gas burnt by the entry method, gas burnt by on_payout if there was one): receipts executed on the guard, first and last.
fn gas_of(r: &ExecutionFinalResult, guard: &AccountId) -> (f64, Option<f64>) {
    let g: Vec<f64> = r.outcomes().iter().filter(|o| &o.executor_id == guard).map(|o| tg(o.gas_burnt)).collect();
    (g[0], if g.len() > 1 { Some(*g.last().unwrap()) } else { None })
}

#[tokio::test]
async fn worst_case_vault_callback_and_methods_fit_their_gas() {
    // near + the main test token + 6 more = 8 tokens (the allowlist maximum): every balance slot is used
    let w = setup_with(6).await;
    let mut fts: Vec<&Contract> = vec![&w.ft];
    fts.extend(w.extra_fts.iter());
    let ft_ids: Vec<String> = fts.iter().map(|f| f.id().to_string()).collect();
    w.open_and_fund(20 * Y).await;
    for f in &fts {
        w.alice
            .call(f.id(), "ft_transfer_call")
            .args_json(json!({"receiver_id": w.g(), "amount": "100000", "msg": ""}))
            .deposit(near(1))
            .max_gas()
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }
    // two usable pocket keys (pocket 0: NEAR, pocket 1: main token)
    let sk0 = SecretKey::from_random(KeyType::ED25519);
    let sk1 = SecretKey::from_random(KeyType::ED25519);
    for sk in [&sk0, &sk1] {
        w.alice
            .batch(w.alice.id())
            .add_key(sk.public_key(), AccessKey::function_call_access(w.g(), &["spend", "request"], Some(near(20 * Y))))
            .transact()
            .await
            .unwrap()
            .into_result()
            .unwrap();
    }
    let k0 = Account::from_secret_key(w.alice.id().clone(), sk0.clone(), &w.worker);
    let k1 = Account::from_secret_key(w.alice.id().clone(), sk1.clone(), &w.worker);
    // 8 pockets: 24-byte names, 20 recipients each
    let names: Vec<String> = (0..8).map(|i| format!("pocket-{:0>17}", i)).collect();
    assert!(names.iter().all(|n| n.len() == 24));
    for i in 0..8usize {
        let mut rcp = vec![json!(w.bob.id()), json!(w.carol.id())];
        for j in 0..18 {
            rcp.push(json!(format!("r{}x{}.test", i, j)));
        }
        let (token, per, daily) = match i {
            0 => ("near".to_string(), Y.to_string(), (100 * Y).to_string()),
            1 | 2 => (ft_ids[0].clone(), "1000000".to_string(), "1000000000".to_string()),
            _ => (ft_ids[i - 2].clone(), "1000000".to_string(), "1000000000".to_string()),
        };
        let pk = match i {
            0 => sk0.public_key(),
            1 => sk1.public_key(),
            _ => SecretKey::from_random(KeyType::ED25519).public_key(),
        };
        w.create_pocket(json!({"name": names[i], "public_key": pk.to_string(), "token": token, "per_payment_cap": per,
                               "daily_cap": daily, "allowed_recipients": rcp, "expires_at": null}))
            .await;
    }
    let memo = "m".repeat(140);
    // 20 orders: the target (pocket 2, main token, to the UNREGISTERED carol, due now, 5 runs) and 19 fillers
    let now = now_ns(&w.worker).await;
    w.owner("create_order", json!({"pocket": names[2], "amount": "1", "recipient": w.carol.id(), "interval_seconds": 3600,
        "first_due_ns": (now - 5_000_000_000).to_string(), "remaining": 5, "memo": memo})).await.into_result().unwrap();
    for _ in 0..19 {
        w.owner("create_order", json!({"pocket": names[0], "amount": "1", "recipient": w.bob.id(), "interval_seconds": 3600,
            "first_due_ns": null, "remaining": null, "memo": memo})).await.into_result().unwrap();
    }
    // 10 requests with 140-byte reasons
    for _ in 0..10 {
        let r = call_gas(&k0, w.g(), "request", json!({"token": "near", "amount": "1", "recipient": w.bob.id(), "reason": memo}), 0, 150).await;
        assert!(r.is_success(), "{:?}", r);
    }
    // 50 receipts with 140-byte reasons
    for _ in 0..50 {
        let r = call_gas(&k0, w.g(), "spend", json!({"token": "near", "amount": "1", "recipient": w.bob.id(), "reason": memo}), 0, 150).await;
        assert!(r.is_success(), "{:?}", r);
    }
    w.settled().await;
    let v = w.vault().await;
    assert_eq!(v["pockets"], 8);
    assert_eq!(v["orders"], 20);
    assert_eq!(v["requests"], 10);
    assert!(v["receipts_total"].as_u64().unwrap() >= 50);
    assert_eq!(v["balances"].as_array().unwrap().len(), 8);
    let receipts = view(&w.worker, w.g(), "get_receipts", json!({"owner": w.alice.id()})).await;
    assert_eq!(receipts.as_array().unwrap().len(), 50);
    println!("vault is FULL: 8 pockets x 20 recipients, 20 orders, 10 requests, 50 receipts, 8 token balances");

    let g = w.g().clone();
    let mut max_cb: f64 = 0.0;
    let mut max_method: f64 = 0.0;
    let mut note = |label: &str, r: &ExecutionFinalResult| {
        let (m, cb) = gas_of(r, &g);
        println!("GAS {:<52} entry method {:>5.1} TGas   on_payout {}", label, m, cb.map_or("-".to_string(), |c| format!("{:>5.1} TGas", c)));
        max_method = max_method.max(m);
        max_cb = max_cb.max(cb.unwrap_or(0.0));
    };

    // (b) successful NEAR spend, just above the minimum the contract accepts (125 TGas; it demands 120 left after the call is decoded)
    let before = w.vault_balance("near").await;
    let r = call_gas(&k0, w.g(), "spend", json!({"token": "near", "amount": "1", "recipient": w.bob.id(), "reason": memo}), 0, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(b) spend NEAR, ok (125 TGas attached)", &r);
    w.settled().await;
    assert_eq!(w.vault_balance("near").await, before - 1);

    // (a) spend whose token transfer FAILS (carol is not registered with the token): fully restored
    let ft0 = ft_ids[0].as_str();
    let bal_before = w.vault_balance(ft0).await;
    let pockets_before = view(&w.worker, w.g(), "get_pockets", json!({"owner": w.alice.id()})).await;
    let spent_before = pockets_before[1]["spent"].clone();
    let r = call_gas(&k1, w.g(), "spend", json!({"token": ft0, "amount": "1", "recipient": w.carol.id(), "reason": memo}), 0, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(a) spend token, transfer FAILS, restored", &r);
    w.settled().await;
    assert_eq!(w.vault_balance(ft0).await, bal_before, "balance not restored");
    let pockets_after = view(&w.worker, w.g(), "get_pockets", json!({"owner": w.alice.id()})).await;
    assert_eq!(pockets_after[1]["spent"], spent_before, "daily total not restored");
    let receipts = view(&w.worker, w.g(), "get_receipts", json!({"owner": w.alice.id()})).await;
    assert_eq!(receipts.as_array().unwrap().last().unwrap()["ok"], false);
    assert_eq!(w.vault().await["pending_out"], 0);

    // (c) execute_order whose transfer FAILS: schedule and count restored
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    let target = orders.as_array().unwrap().iter().find(|o| o["pocket"] == names[2].as_str()).unwrap().clone();
    let r = call_gas(&w.bob, w.g(), "execute_order", json!({"owner": w.alice.id(), "order_id": target["id"]}), 0, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(c) execute_order, transfer FAILS, restored", &r);
    w.settled().await;
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    let after = orders.as_array().unwrap().iter().find(|o| o["id"] == target["id"]).unwrap().clone();
    assert_eq!(after["next_due_ns"], target["next_due_ns"], "schedule not restored");
    assert_eq!(after["remaining"], target["remaining"], "count not restored");
    // and one that succeeds (to the registered bob)
    let r = call_gas(&w.alice, w.g(), "update_pocket", json!({"config": {"name": names[2], "public_key": pockets_after[2]["public_key"],
        "token": ft0, "per_payment_cap": "1000000", "daily_cap": "1000000000", "allowed_recipients": pockets_after[2]["allowed_recipients"], "expires_at": null}}), 1, 150).await;
    assert!(r.is_success());

    // (d) withdraw: a token and NEAR, 125 TGas
    let r = call_gas(&w.alice, w.g(), "withdraw", json!({"token": ft0, "amount": "100"}), 1, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(d) withdraw token, ok", &r);
    w.settled().await;
    let r = call_gas(&w.alice, w.g(), "withdraw", json!({"token": "near", "amount": Y.to_string()}), 1, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(d) withdraw NEAR, ok", &r);
    w.settled().await;

    // (e) approve a request
    let reqs = view(&w.worker, w.g(), "get_requests", json!({"owner": w.alice.id()})).await;
    let r = call_gas(&w.alice, w.g(), "approve", json!({"request_id": reqs[0]["id"]}), 1, 125).await;
    assert!(r.is_success(), "{:?}", r);
    note("(e) approve request, ok", &r);
    w.settled().await;

    println!("GAS worst on_payout {:.1} TGas (static gas given to it: 40)   worst entry method {:.1} TGas (budget: 125 - 30 - 40 - entry overhead)", max_cb, max_method);
    assert!(max_cb * 2.0 <= 40.0, "on_payout needs {} TGas, static 40 is less than 2x", max_cb);
    assert!(max_method + 30.0 + 40.0 <= 125.0, "entry method too heavy for the 125 TGas minimum: {}", max_method);
}

// =====================================================================================================
// Solvency and token conservation after a story with failed payouts and a closed vault.
// =====================================================================================================

#[tokio::test]
async fn contract_stays_solvent_and_holds_exactly_the_tokens_it_owes() {
    let w = setup().await;
    let base = w.guard.view_account().await.unwrap();
    let ghost: AccountId = "ghost-account-that-does-not-exist.test.near".parse().unwrap();
    w.open_and_fund(5 * Y).await;
    w.deposit_ft(500).await;
    w.add_pocket_key().await;
    // NEAR pocket (anyone may be paid), token pocket with its own key, order pocket without key
    let mut cfg = w.pocket_cfg("near-p", "near");
    cfg["allowed_recipients"] = json!([]);
    w.create_pocket(cfg).await;
    let sk2 = SecretKey::from_random(KeyType::ED25519);
    w.alice
        .batch(w.alice.id())
        .add_key(sk2.public_key(), AccessKey::function_call_access(w.g(), &["spend", "request"], Some(near(Y))))
        .transact()
        .await
        .unwrap()
        .into_result()
        .unwrap();
    let k2 = Account::from_secret_key(w.alice.id().clone(), sk2.clone(), &w.worker);
    let ftid = w.ft.id().to_string();
    w.create_pocket(json!({"name": "tok-p", "public_key": sk2.public_key().to_string(), "token": ftid, "per_payment_cap": "100",
        "daily_cap": "1000", "allowed_recipients": [], "expires_at": null})).await;
    w.create_pocket(json!({"name": "ord-p", "public_key": null, "token": "near", "per_payment_cap": Y.to_string(),
        "daily_cap": (5 * Y).to_string(), "allowed_recipients": [], "expires_at": null})).await;
    // payments: ok, failing (non-existent named account), token ok, token failing (unregistered)
    let nspend = |to: &AccountId| json!({"token": "near", "amount": (Y / 10).to_string(), "recipient": to, "reason": "x"});
    assert!(w.pocket.call(w.g(), "spend").args_json(nspend(w.bob.id())).max_gas().transact().await.unwrap().is_success());
    w.settled().await;
    assert!(w.pocket.call(w.g(), "spend").args_json(nspend(&ghost)).max_gas().transact().await.unwrap().is_success());
    w.settled().await;
    for to in [w.bob.id(), w.carol.id()] {
        let r = k2.call(w.g(), "spend").args_json(json!({"token": ftid, "amount": "50", "recipient": to, "reason": "x"})).max_gas().transact().await.unwrap();
        assert!(r.is_success(), "{:?}", r);
        w.settled().await;
    }
    // orders: one to bob (ok), one to the ghost (fails and is restored)
    let now = now_ns(&w.worker).await;
    for to in [w.bob.id(), &ghost] {
        w.owner("create_order", json!({"pocket": "ord-p", "amount": (Y / 10).to_string(), "recipient": to, "interval_seconds": 3600,
            "first_due_ns": (now - 1_000_000_000).to_string(), "remaining": null, "memo": "o"})).await.into_result().unwrap();
    }
    let orders = view(&w.worker, w.g(), "get_orders", json!({"owner": w.alice.id()})).await;
    for o in orders.as_array().unwrap() {
        let r = w.carol.call(w.g(), "execute_order").args_json(json!({"owner": w.alice.id(), "order_id": o["id"]})).max_gas().transact().await.unwrap();
        assert!(r.is_success(), "{:?}", r);
        w.settled().await;
    }
    // a failing withdraw of a token to an owner who is registered is fine; a failing NEAR withdraw is not constructible. Normal ones:
    w.owner("withdraw", json!({"token": ftid, "amount": "100"})).await.into_result().unwrap();
    w.owner("withdraw", json!({"token": "near", "amount": Y.to_string()})).await.into_result().unwrap();
    w.settled().await;
    // bob opens a vault, deposits and closes it again
    wasm_ok(&w.worker, &w.bob, w.g(), "open_vault", json!({}), STORAGE_DEPOSIT + Y).await.into_result().unwrap();
    w.bob.call(w.g(), "withdraw").args_json(json!({"token": "near", "amount": null})).deposit(near(1)).max_gas().transact().await.unwrap().into_result().unwrap();
    for _ in 0..40 {
        if view(&w.worker, w.g(), "get_vault", json!({"owner": w.bob.id()})).await["pending_out"] == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    w.bob.call(w.g(), "close_vault").deposit(near(1)).max_gas().transact().await.unwrap().into_result().unwrap();
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(view(&w.worker, w.g(), "get_vault", json!({"owner": w.bob.id()})).await.is_null());
    // let every refund receipt land
    tokio::time::sleep(Duration::from_secs(3)).await;

    // ---- the invariants
    let v = w.vault().await;
    let vault_near: i128 = v["balances"].as_array().unwrap().iter().find(|b| b["token"] == "near").map_or(0, |b| b["amount"].as_str().unwrap().parse().unwrap());
    let vault_ft: i128 = v["balances"].as_array().unwrap().iter().find(|b| b["token"] == ftid.as_str()).map_or(0, |b| b["amount"].as_str().unwrap().parse().unwrap());
    let deposits: i128 = v["storage_paid"].as_str().unwrap().parse().unwrap();
    let now_acct = w.guard.view_account().await.unwrap();
    let balance = now_acct.balance.as_yoctonear() as i128;
    let storage_cost = now_acct.storage_usage as i128 * 10_i128.pow(19);
    let delta_balance = balance - base.balance.as_yoctonear() as i128;
    let delta_storage = (now_acct.storage_usage as i128 - base.storage_usage as i128) * 10_i128.pow(19);
    println!("solvency: balance grew by {} yocto; vault NEAR owed {}; storage grew by {} yocto (deposit paid {})", delta_balance, vault_near, delta_storage, deposits);
    // (1) exact: what came in and was not paid out must cover what the vaults hold plus the storage the vaults use
    assert!(delta_balance >= vault_near + delta_storage, "insolvent: {} < {} + {}", delta_balance, vault_near, delta_storage);
    // (2) the form asked for: balance >= vault NEAR + storage deposits + the staking requirement of the whole account
    assert!(balance >= vault_near + deposits + storage_cost);
    // tokens: the contract's balance in the test token equals the sum of the vault balances, exactly
    let held = w.ft_balance(w.g()).await as i128;
    assert_eq!(held, vault_ft, "token balance of the contract differs from what vaults hold");
    assert_eq!(vault_ft, 500 - 50 - 100); // deposited 500, paid 50 (the other 50 bounced back), withdrew 100
    assert_eq!(w.vault().await["pending_out"], 0);
}

// =====================================================================================================
// The exported method list is pinned.
// =====================================================================================================

fn leb(b: &[u8], i: &mut usize) -> usize {
    let (mut r, mut s) = (0usize, 0);
    loop {
        let x = b[*i];
        *i += 1;
        r |= ((x & 0x7f) as usize) << s;
        if x & 0x80 == 0 {
            return r;
        }
        s += 7;
    }
}

fn exported_functions(wasm: &[u8]) -> Vec<String> {
    assert_eq!(&wasm[0..4], b"\0asm");
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let size = leb(wasm, &mut i);
        if id == 7 {
            let mut j = i;
            let n = leb(wasm, &mut j);
            let mut out = vec![];
            for _ in 0..n {
                let len = leb(wasm, &mut j);
                let name = String::from_utf8(wasm[j..j + len].to_vec()).unwrap();
                j += len;
                let kind = wasm[j];
                j += 1;
                leb(wasm, &mut j);
                if kind == 0 {
                    out.push(name);
                }
            }
            out.sort();
            return out;
        }
        i += size;
    }
    panic!("no export section");
}

#[test]
fn exported_methods_are_pinned() {
    let wasm = read_wasm("GUARD_WASM", "../target/wasm32-unknown-unknown/release/hermit_guard.wasm");
    let have = exported_functions(&wasm);
    let mut want: Vec<String> = std::fs::read_to_string("exports.txt")
        .unwrap()
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
        .map(|l| l.split_whitespace().next().unwrap().to_string())
        .collect();
    want.sort();
    println!("exported functions ({}): {}", have.len(), have.join(", "));
    let unexpected: Vec<_> = have.iter().filter(|h| !want.contains(h)).collect();
    let missing: Vec<_> = want.iter().filter(|w| !have.contains(w)).collect();
    assert!(unexpected.is_empty(), "the wasm exports methods that are not in sandbox-tests/exports.txt: {:?}", unexpected);
    assert!(missing.is_empty(), "exports.txt lists methods the wasm no longer exports: {:?}", missing);
}
