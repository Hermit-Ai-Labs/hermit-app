//! Unit tests: every rule and every limit, in the mocked blockchain (no sandbox).
use super::*;
use near_sdk::test_utils::{get_logs, VMContextBuilder};
use near_sdk::{test_vm_config, testing_env, CurveType, RuntimeFeesConfig};
use std::panic::{catch_unwind, AssertUnwindSafe};

const T0: u64 = 1_700_000_000_000_000_000;
const Y: u128 = 1_000_000_000_000_000_000_000_000; // 1 NEAR
const HOUR_NS: u64 = 3_600_000_000_000;

fn acc(s: &str) -> AccountId {
    s.parse().unwrap()
}

fn pk(n: u8) -> PublicKey {
    PublicKey::from_parts(CurveType::ED25519, vec![n; 32]).unwrap()
}

fn context(who: &str, key: Option<u8>, deposit: u128, ts: u64) -> VMContextBuilder {
    let mut b = VMContextBuilder::new();
    b.current_account_id(acc("guard.test"))
        .predecessor_account_id(acc(who))
        .signer_account_id(acc(who))
        .attached_deposit(NearToken::from_yoctonear(deposit))
        .account_balance(NearToken::from_near(1_000_000))
        .block_timestamp(ts)
        .prepaid_gas(Gas::from_tgas(300));
    if let Some(k) = key {
        b.signer_account_pk(pk(k));
    }
    b
}

fn env_as(who: &str, key: Option<u8>, deposit: u128, ts: u64) {
    testing_env!(context(who, key, deposit, ts).build());
}

/// Owner call: full-access key, exactly 1 yocto.
fn owner(who: &str, ts: u64) {
    env_as(who, Some(99), 1, ts);
}

/// Pocket-key call: function-call key number `k`, no deposit.
fn pocket_key(who: &str, k: u8, ts: u64) {
    env_as(who, Some(k), 0, ts);
}

/// A call from the contract itself with the given result of the promise it is settling.
fn settle_env(result: PromiseResult, ts: u64) {
    testing_env!(
        context("guard.test", None, 0, ts).build(),
        test_vm_config(),
        RuntimeFeesConfig::test(),
        Default::default(),
        vec![result]
    );
}

fn panics<F: FnOnce()>(f: F) -> bool {
    catch_unwind(AssertUnwindSafe(f)).is_err()
}

fn guard() -> Guard {
    env_as("guard.test", None, 0, T0);
    Guard::new(vec!["near".to_string(), "usdc.test".to_string()])
}

fn cfg(name: &str, key: Option<u8>) -> PocketConfig {
    PocketConfig {
        name: name.to_string(),
        public_key: key.map(pk),
        token: "near".to_string(),
        per_payment_cap: U128(Y),
        daily_cap: U128(3 * Y),
        allowed_recipients: vec![],
        expires_at: None,
    }
}

/// alice has a vault with 10 NEAR and a pocket "coffee" (key 1): 1 NEAR per payment, 3 NEAR per day.
fn base() -> Guard {
    let mut g = guard();
    env_as("alice.test", None, STORAGE_DEPOSIT, T0);
    g.open_vault();
    env_as("alice.test", None, 10 * Y, T0);
    g.deposit_near();
    owner("alice.test", T0);
    g.create_pocket(cfg("coffee", Some(1)));
    g
}

fn spend(g: &mut Guard, amount: u128, to: &str, ts: u64) {
    pocket_key("alice.test", 1, ts);
    let _ = g.spend("near".to_string(), U128(amount), acc(to), "test".to_string());
}

fn near_balance(g: &Guard) -> u128 {
    g.load(&acc("alice.test")).balance("near")
}

fn pocket(g: &Guard, name: &str) -> Pocket {
    g.get_pockets(acc("alice.test")).into_iter().find(|p| p.name == name).unwrap()
}

// ---------------------------------------------------------------- init, open, deposit

#[test]
fn init_checks_allowlist() {
    env_as("guard.test", None, 0, T0);
    assert!(panics(|| {
        Guard::new(vec!["usdc.test".to_string()]);
    }));
    assert!(panics(|| {
        Guard::new(vec!["near".to_string(), "near".to_string()]);
    }));
    assert!(panics(|| {
        Guard::new(vec!["near".to_string(), "Not A Valid Id".to_string()]);
    }));
    let nine: Vec<String> = std::iter::once("near".to_string()).chain((0..8).map(|i| format!("t{}.test", i))).collect();
    assert!(panics(|| {
        Guard::new(nine);
    }));
    let g = Guard::new(vec!["near".to_string(), "usdc.test".to_string()]);
    assert_eq!(g.get_tokens().len(), 2);
    assert_eq!(g.version(), "1.0.0");
    assert_eq!(g.storage_cost().0, STORAGE_DEPOSIT);
}

#[test]
fn open_vault_needs_the_storage_deposit_once() {
    let mut g = guard();
    env_as("alice.test", None, STORAGE_DEPOSIT - 1, T0);
    assert!(panics(|| g.open_vault()));
    env_as("alice.test", None, STORAGE_DEPOSIT + 5 * Y, T0);
    g.open_vault();
    let v = g.get_vault(acc("alice.test")).unwrap();
    assert_eq!(v.storage_paid.0, STORAGE_DEPOSIT);
    assert_eq!(v.balances[0].amount.0, 5 * Y); // the excess is the first NEAR deposit
    assert!(get_logs().iter().any(|l| l.contains("\"event\":\"vault_opened\"")));
    env_as("alice.test", None, STORAGE_DEPOSIT, T0);
    assert!(panics(|| g.open_vault())); // already open
    assert_eq!(g.owners_count(), 1);
}

#[test]
fn deposit_near_needs_vault_and_amount() {
    let mut g = guard();
    env_as("bob.test", None, Y, T0);
    assert!(panics(|| g.deposit_near())); // no vault
    let mut g = base();
    env_as("alice.test", None, 0, T0);
    assert!(panics(|| g.deposit_near()));
    env_as("alice.test", None, Y, T0);
    g.deposit_near();
    assert_eq!(near_balance(&g), 11 * Y);
    assert!(get_logs().iter().any(|l| l.contains("\"event\":\"deposit\"")));
}

#[test]
fn ft_on_transfer_credits_only_allowlisted_tokens_with_a_vault() {
    let mut g = base();
    env_as("usdc.test", None, 0, T0);
    assert_eq!(g.ft_on_transfer(acc("alice.test"), U128(500), String::new()).0, 0);
    assert_eq!(g.load(&acc("alice.test")).balance("usdc.test"), 500);
    // sender without a vault: everything is returned
    assert_eq!(g.ft_on_transfer(acc("bob.test"), U128(500), String::new()).0, 500);
    // token not on the list: everything is returned, nothing credited
    env_as("evil.test", None, 0, T0);
    assert_eq!(g.ft_on_transfer(acc("alice.test"), U128(500), String::new()).0, 500);
    assert_eq!(g.load(&acc("alice.test")).balance("evil.test"), 0);
    // a person calling it directly is not an allowlisted token
    env_as("alice.test", None, 0, T0);
    assert_eq!(g.ft_on_transfer(acc("alice.test"), U128(7), String::new()).0, 7);
    // overflow is returned, not credited
    env_as("usdc.test", None, 0, T0);
    assert_eq!(g.ft_on_transfer(acc("alice.test"), U128(u128::MAX), String::new()).0, u128::MAX);
}

// ---------------------------------------------------------------- storage bounds

#[test]
fn worst_case_vault_fits_the_deposit() {
    let long_id = "a".repeat(64);
    let acct = acc(&long_id);
    let text = "x".repeat(MAX_TEXT_BYTES);
    let name = "n".repeat(MAX_NAME_BYTES);
    let big_key = PublicKey::from_parts(CurveType::SECP256K1, vec![1u8; 64]).unwrap();
    let mut v = Vault::new(u32::MAX, STORAGE_DEPOSIT);
    v.frozen = true;
    v.receipts_total = u64::MAX;
    v.next_id = u64::MAX;
    v.pending_out = u32::MAX;
    for _ in 0..MAX_TOKENS {
        v.balances.push(TokenBalance { token: long_id.clone(), amount: U128(u128::MAX) });
    }
    for _ in 0..MAX_POCKETS {
        v.pockets.push(Pocket {
            name: name.clone(),
            public_key: Some(big_key.clone()),
            token: long_id.clone(),
            per_payment_cap: U128(u128::MAX),
            daily_cap: U128(u128::MAX),
            spent: U128(u128::MAX),
            window_start: U64(u64::MAX),
            allowed_recipients: vec![acct.clone(); MAX_RECIPIENTS],
            expires_at: Some(U64(u64::MAX)),
            paused: true,
        });
    }
    for _ in 0..MAX_ORDERS {
        v.orders.push(Order {
            id: u64::MAX,
            pocket: name.clone(),
            token: long_id.clone(),
            amount: U128(u128::MAX),
            recipient: acct.clone(),
            interval_seconds: u64::MAX,
            next_due_ns: U64(u64::MAX),
            remaining: Some(u32::MAX),
            memo: text.clone(),
        });
    }
    for _ in 0..MAX_REQUESTS {
        v.requests.push(Request {
            id: u64::MAX,
            pocket: name.clone(),
            token: long_id.clone(),
            amount: U128(u128::MAX),
            recipient: acct.clone(),
            reason: text.clone(),
            created_ns: U64(u64::MAX),
        });
    }
    for _ in 0..MAX_RECEIPTS {
        v.receipts.push(Receipt {
            id: u64::MAX,
            time: U64(u64::MAX),
            pocket: name.clone(),
            token: long_id.clone(),
            amount: U128(u128::MAX),
            recipient: acct.clone(),
            reason: text.clone(),
            kind: Kind::Approved,
            ok: false,
        });
    }
    let size = near_sdk::borsh::to_vec(&v).unwrap().len() as u64;
    println!("worst-case vault: {} bytes of {} prepaid (overhead allowance 1000)", size, STORAGE_DEPOSIT_BYTES);
    assert!(size + 1000 <= STORAGE_DEPOSIT_BYTES);
    assert_eq!(STORAGE_DEPOSIT, STORAGE_DEPOSIT_BYTES as u128 * env::storage_byte_cost().as_yoctonear());
}

#[test]
fn ninth_pocket_is_refused() {
    let mut g = base(); // coffee is pocket 1
    for i in 2..=MAX_POCKETS {
        owner("alice.test", T0);
        g.create_pocket(cfg(&format!("p{}", i), Some(i as u8 + 10)));
    }
    assert_eq!(g.get_pockets(acc("alice.test")).len(), 8);
    owner("alice.test", T0);
    assert!(panics(|| g.create_pocket(cfg("ninth", Some(77)))));
}

#[test]
fn pocket_input_limits() {
    let mut g = base();
    owner("alice.test", T0);
    assert!(panics(|| g.create_pocket(cfg("coffee", Some(2))))); // same name
    assert!(panics(|| g.create_pocket(cfg("other", Some(1))))); // same key
    assert!(panics(|| g.create_pocket(cfg("", Some(2)))));
    assert!(panics(|| g.create_pocket(cfg(&"n".repeat(25), Some(2)))));
    let mut c = cfg("rcp", Some(2));
    c.allowed_recipients = (0..21).map(|i| acc(&format!("r{}.test", i))).collect();
    assert!(panics(|| g.create_pocket(c)));
    let mut c = cfg("past", Some(2));
    c.expires_at = Some(U64(T0 - 1));
    assert!(panics(|| g.create_pocket(c)));
    let mut c = cfg("tok", Some(2));
    c.token = "evil.test".to_string();
    assert!(panics(|| g.create_pocket(c)));
    let mut c = cfg("caps", Some(2));
    c.daily_cap = U128(Y - 1);
    assert!(panics(|| g.create_pocket(c)));
    let mut c = cfg("zero", Some(2));
    c.per_payment_cap = U128(0);
    assert!(panics(|| g.create_pocket(c)));
    // a pocket with no key (orders only) is fine, and so are 20 recipients
    let mut c = cfg("orders-only", None);
    c.allowed_recipients = (0..20).map(|i| acc(&format!("r{}.test", i))).collect();
    g.create_pocket(c);
    assert_eq!(g.get_pockets(acc("alice.test")).len(), 2);
}

#[test]
fn update_pause_remove_pocket() {
    let mut g = base();
    spend(&mut g, Y / 2, "bob.test", T0);
    owner("alice.test", T0);
    let mut c = cfg("coffee", Some(1));
    c.per_payment_cap = U128(2 * Y);
    c.daily_cap = U128(5 * Y);
    g.update_pocket(c);
    let p = pocket(&g, "coffee");
    assert_eq!(p.per_payment_cap.0, 2 * Y);
    assert_eq!(p.spent.0, Y / 2); // the window is kept
    owner("alice.test", T0);
    assert!(panics(|| g.update_pocket(cfg("nope", None))));
    g.pause_pocket("coffee".into());
    assert!(pocket(&g, "coffee").paused);
    g.resume_pocket("coffee".into());
    assert!(!pocket(&g, "coffee").paused);
    // orders and requests of a removed pocket go with it
    g.create_order("coffee".into(), U128(Y), acc("bob.test"), 3600, None, None, "m".into());
    pocket_key("alice.test", 1, T0);
    g.request("near".into(), U128(5 * Y), acc("bob.test"), "r".into());
    owner("alice.test", T0);
    g.remove_pocket("coffee".into());
    assert!(g.get_pockets(acc("alice.test")).is_empty());
    assert!(g.get_orders(acc("alice.test")).is_empty());
    assert!(g.get_requests(acc("alice.test")).is_empty());
    owner("alice.test", T0);
    assert!(panics(|| g.remove_pocket("coffee".into())));
}

// ---------------------------------------------------------------- spend rules

#[test]
fn spend_within_caps_pays_and_records() {
    let mut g = base();
    spend(&mut g, Y, "bob.test", T0);
    assert_eq!(near_balance(&g), 9 * Y);
    let p = pocket(&g, "coffee");
    assert_eq!(p.spent.0, Y);
    assert_eq!(p.window_start.0, T0);
    let v = g.get_vault(acc("alice.test")).unwrap();
    assert_eq!(v.pending_out, 1);
    let r = g.get_receipts(acc("alice.test"));
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].kind, Kind::Spend);
    assert!(r[0].ok);
    assert_eq!(r[0].recipient, acc("bob.test"));
    assert!(get_logs().iter().any(|l| l.starts_with("EVENT_JSON:") && l.contains("\"event\":\"spend\"") && l.contains("hermit-guard")));
}

#[test]
fn spend_over_per_payment_cap_is_refused() {
    let mut g = base();
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(Y + 1), acc("bob.test"), "x".into());
    }));
    assert_eq!(near_balance(&g), 10 * Y);
}

#[test]
fn daily_cap_holds_and_resets_after_the_window() {
    let mut g = base();
    for _ in 0..3 {
        spend(&mut g, Y, "bob.test", T0 + 1000);
    }
    pocket_key("alice.test", 1, T0 + 2000);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    assert_eq!(pocket(&g, "coffee").spent.0, 3 * Y);
    // still the same window one nanosecond before it ends
    pocket_key("alice.test", 1, T0 + 1000 + DAY_NS - 1);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // a new window opens after 24h
    spend(&mut g, Y, "bob.test", T0 + 1000 + DAY_NS);
    let p = pocket(&g, "coffee");
    assert_eq!(p.spent.0, Y);
    assert_eq!(p.window_start.0, T0 + 1000 + DAY_NS);
}

#[test]
fn spend_refusals() {
    let mut g = base();
    let try_spend = |g: &mut Guard, token: &str, amount: u128, to: &str, reason: &str| -> bool {
        pocket_key("alice.test", 1, T0);
        panics(|| {
            let _ = g.spend(token.into(), U128(amount), acc(to), reason.into());
        })
    };
    assert!(try_spend(&mut g, "usdc.test", 1, "bob.test", "")); // wrong token
    assert!(try_spend(&mut g, "near", 0, "bob.test", "")); // zero
    assert!(try_spend(&mut g, "near", 1, "guard.test", "")); // to the contract itself
    assert!(try_spend(&mut g, "near", 1, "bob.test", &"x".repeat(141))); // reason too long
    assert!(!try_spend(&mut g, "near", 1, "bob.test", &"x".repeat(140)));
    // not enough in the vault
    owner("alice.test", T0);
    g.withdraw("near".into(), Some(U128(10 * Y - 1)));
    assert!(try_spend(&mut g, "near", Y, "bob.test", ""));
}

#[test]
fn spend_to_non_allowed_recipient_is_refused() {
    let mut g = base();
    owner("alice.test", T0);
    let mut c = cfg("coffee", Some(1));
    c.allowed_recipients = vec![acc("cafe.test")];
    g.update_pocket(c);
    spend(&mut g, 1, "cafe.test", T0);
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
}

#[test]
fn spend_after_expiry_paused_or_frozen_is_refused() {
    let mut g = base();
    owner("alice.test", T0);
    let mut c = cfg("coffee", Some(1));
    c.expires_at = Some(U64(T0 + HOUR_NS));
    g.update_pocket(c);
    spend(&mut g, 1, "bob.test", T0 + HOUR_NS - 1);
    pocket_key("alice.test", 1, T0 + HOUR_NS);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // paused
    let mut g = base();
    owner("alice.test", T0);
    g.pause_pocket("coffee".into());
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    owner("alice.test", T0);
    g.resume_pocket("coffee".into());
    spend(&mut g, 1, "bob.test", T0);
    // frozen, then unfrozen
    owner("alice.test", T0);
    g.freeze();
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    owner("alice.test", T0);
    g.unfreeze();
    spend(&mut g, 1, "bob.test", T0);
}

#[test]
fn only_a_pocket_key_called_directly_can_spend() {
    let mut g = base();
    // owner's own full-access key (not a pocket key)
    env_as("alice.test", Some(99), 0, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // unknown key
    pocket_key("alice.test", 5, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // alice's pocket key presented by a stranger: stranger has no vault
    pocket_key("bob.test", 1, T0);
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // a contract calling on behalf of the key (predecessor != signer)
    testing_env!(context("alice.test", Some(1), 0, T0).signer_account_id(acc("mallory.test")).build());
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    // too little gas
    testing_env!(context("alice.test", Some(1), 0, T0).prepaid_gas(Gas::from_tgas(50)).build());
    assert!(panics(|| {
        let _ = g.spend("near".into(), U128(1), acc("bob.test"), "x".into());
    }));
    assert_eq!(near_balance(&g), 10 * Y);
}

#[test]
fn stranger_cannot_touch_another_vault() {
    let mut g = base();
    env_as("bob.test", None, STORAGE_DEPOSIT, T0);
    g.open_vault();
    owner("bob.test", T0);
    // bob's withdraw only ever reads bob's vault: nothing there
    assert!(panics(|| {
        let _ = g.withdraw("near".into(), None);
    }));
    assert_eq!(near_balance(&g), 10 * Y);
    // carol has no vault at all
    owner("carol.test", T0);
    assert!(panics(|| {
        let _ = g.withdraw("near".into(), Some(U128(1)));
    }));
    assert!(panics(|| g.freeze()));
}

#[test]
fn every_owner_method_needs_exactly_one_yocto() {
    let mut g = base();
    spend(&mut g, 1, "bob.test", T0);
    pocket_key("alice.test", 1, T0);
    g.request("near".into(), U128(5 * Y), acc("bob.test"), "r".into());
    owner("alice.test", T0);
    g.create_order("coffee".into(), U128(1), acc("bob.test"), 3600, None, None, "m".into());
    for deposit in [0u128, 2, Y] {
        env_as("alice.test", Some(1), deposit, T0);
        assert!(panics(|| g.close_vault().then_noop()), "close_vault {}", deposit);
        assert!(panics(|| g.create_pocket(cfg("z", Some(9)))), "create_pocket {}", deposit);
        assert!(panics(|| g.update_pocket(cfg("coffee", Some(1)))), "update_pocket {}", deposit);
        assert!(panics(|| g.remove_pocket("coffee".into())), "remove_pocket {}", deposit);
        assert!(panics(|| g.pause_pocket("coffee".into())), "pause_pocket {}", deposit);
        assert!(panics(|| g.resume_pocket("coffee".into())), "resume_pocket {}", deposit);
        assert!(
            panics(|| {
                g.create_order("coffee".into(), U128(1), acc("bob.test"), 3600, None, None, "".into());
            }),
            "create_order {}",
            deposit
        );
        assert!(panics(|| g.cancel_order(1)), "cancel_order {}", deposit);
        assert!(panics(|| g.approve(1).then_noop()), "approve {}", deposit);
        assert!(panics(|| g.reject(1)), "reject {}", deposit);
        assert!(panics(|| g.freeze()), "freeze {}", deposit);
        assert!(panics(|| g.unfreeze()), "unfreeze {}", deposit);
        assert!(panics(|| g.withdraw("near".into(), None).then_noop()), "withdraw {}", deposit);
    }
    // nothing changed
    let v = g.get_vault(acc("alice.test")).unwrap();
    assert!(!v.frozen);
    assert_eq!(v.pockets, 1);
    assert_eq!(v.orders, 1);
    assert_eq!(v.requests, 1);
}

trait ThenNoop {
    fn then_noop(self);
}
impl ThenNoop for Promise {
    fn then_noop(self) {}
}

// ---------------------------------------------------------------- requests

#[test]
fn request_then_approve_pays() {
    let mut g = base();
    pocket_key("alice.test", 1, T0);
    let id = g.request("near".into(), U128(5 * Y), acc("shop.test"), "new laptop".into()); // over the caps
    assert_eq!(g.get_requests(acc("alice.test")).len(), 1);
    assert_eq!(near_balance(&g), 10 * Y); // a request pays nothing
    owner("alice.test", T0 + 1);
    let _ = g.approve(id);
    assert_eq!(near_balance(&g), 5 * Y);
    assert!(g.get_requests(acc("alice.test")).is_empty());
    let r = g.get_receipts(acc("alice.test"));
    assert_eq!(r[0].kind, Kind::Approved);
    assert_eq!(pocket(&g, "coffee").spent.0, 0); // an approval does not use up the daily cap
    let logs = get_logs();
    assert!(logs.iter().any(|l| l.contains("\"event\":\"approved\"")));
    owner("alice.test", T0 + 1);
    assert!(panics(|| {
        let _ = g.approve(id);
    })); // already used
}

#[test]
fn request_reject_frozen_expiry_and_limits() {
    let mut g = base();
    pocket_key("alice.test", 1, T0);
    let id = g.request("near".into(), U128(5 * Y), acc("shop.test"), "x".into());
    owner("alice.test", T0);
    g.reject(id);
    assert!(get_logs().iter().any(|l| l.contains("\"event\":\"rejected\"")));
    assert!(g.get_requests(acc("alice.test")).is_empty());
    // frozen: approve refused, request refused
    pocket_key("alice.test", 1, T0);
    let id = g.request("near".into(), U128(5 * Y), acc("shop.test"), "x".into());
    owner("alice.test", T0);
    g.freeze();
    assert!(panics(|| {
        let _ = g.approve(id);
    }));
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        g.request("near".into(), U128(1), acc("shop.test"), "x".into());
    }));
    owner("alice.test", T0);
    g.unfreeze();
    // 7 days
    owner("alice.test", T0 + REQUEST_TTL_NS);
    assert!(panics(|| {
        let _ = g.approve(id);
    }));
    env_as("alice.test", None, 0, T0 + REQUEST_TTL_NS);
    assert!(g.get_requests(acc("alice.test")).is_empty()); // hidden in the view
    // more than the vault holds cannot be approved
    pocket_key("alice.test", 1, T0);
    let big = g.request("near".into(), U128(11 * Y), acc("shop.test"), "x".into());
    owner("alice.test", T0);
    assert!(panics(|| {
        let _ = g.approve(big);
    }));
}

#[test]
fn eleventh_request_refused_and_old_ones_are_cleaned() {
    let mut g = base();
    pocket_key("alice.test", 1, T0);
    for _ in 0..MAX_REQUESTS - 1 {
        g.request("near".into(), U128(1), acc("shop.test"), "x".into()); // one is already pending from the loop below
    }
    g.request("near".into(), U128(1), acc("shop.test"), "x".into());
    assert!(panics(|| {
        g.request("near".into(), U128(1), acc("shop.test"), "x".into());
    }));
    // after 7 days the old ones are dropped when a new one comes in
    pocket_key("alice.test", 1, T0 + REQUEST_TTL_NS);
    g.request("near".into(), U128(1), acc("shop.test"), "fresh".into());
    assert_eq!(g.load(&acc("alice.test")).requests.len(), 1);
    // wrong token
    pocket_key("alice.test", 1, T0);
    assert!(panics(|| {
        g.request("usdc.test".into(), U128(1), acc("shop.test"), "x".into());
    }));
}

// ---------------------------------------------------------------- standing orders

fn order_world() -> Guard {
    // pocket "rent": no key, 2 NEAR per payment, 10 per day; order of 1 NEAR to landlord every hour, first due at T0
    let mut g = base();
    owner("alice.test", T0);
    let mut c = cfg("rent", None);
    c.per_payment_cap = U128(2 * Y);
    c.daily_cap = U128(10 * Y);
    c.allowed_recipients = vec![acc("landlord.test")];
    g.create_pocket(c);
    owner("alice.test", T0);
    let id = g.create_order("rent".into(), U128(Y), acc("landlord.test"), 3600, Some(U64(T0)), None, "rent".into());
    assert_eq!(id, 1);
    g
}

fn run_order(g: &mut Guard, ts: u64) {
    env_as("anyone.test", None, 0, ts);
    let _ = g.execute_order(acc("alice.test"), 1);
}

#[test]
fn order_not_due_is_refused_and_changes_nothing() {
    let mut g = base();
    owner("alice.test", T0);
    g.create_order("coffee".into(), U128(Y), acc("bob.test"), 3600, None, None, "x".into()); // first due: T0 + 1h
    env_as("anyone.test", None, 0, T0 + HOUR_NS - 1);
    assert!(g.due_orders(0, 10).is_empty());
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
    assert_eq!(near_balance(&g), 10 * Y);
    assert_eq!(g.get_orders(acc("alice.test"))[0].next_due_ns.0, T0 + HOUR_NS);
    env_as("anyone.test", None, 0, T0 + HOUR_NS);
    assert_eq!(g.due_orders(0, 10).len(), 1);
}

#[test]
fn due_order_pays_for_anyone_once_per_period() {
    let mut g = order_world();
    env_as("anyone.test", None, 0, T0);
    assert_eq!(g.due_orders(0, 10).len(), 1);
    run_order(&mut g, T0);
    assert_eq!(near_balance(&g), 9 * Y);
    assert_eq!(g.get_receipts(acc("alice.test"))[0].kind, Kind::Order);
    assert_eq!(g.get_orders(acc("alice.test"))[0].next_due_ns.0, T0 + HOUR_NS);
    assert!(get_logs().iter().any(|l| l.contains("\"event\":\"order_paid\"")));
    // same period: refused
    env_as("anyone.test", None, 0, T0 + 5);
    assert!(g.due_orders(0, 10).is_empty());
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
    assert_eq!(near_balance(&g), 9 * Y);
}

#[test]
fn missed_periods_do_not_pile_up() {
    let mut g = order_world();
    // three and a half intervals late: one payment, next due at T0 + 4h
    run_order(&mut g, T0 + 3 * HOUR_NS + HOUR_NS / 2);
    assert_eq!(near_balance(&g), 9 * Y);
    assert_eq!(g.get_orders(acc("alice.test"))[0].next_due_ns.0, T0 + 4 * HOUR_NS);
    env_as("anyone.test", None, 0, T0 + 3 * HOUR_NS + HOUR_NS / 2 + 1);
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
    // exactly on a boundary moves to the following one
    let mut g = order_world();
    run_order(&mut g, T0 + 2 * HOUR_NS);
    assert_eq!(g.get_orders(acc("alice.test"))[0].next_due_ns.0, T0 + 3 * HOUR_NS);
}

#[test]
fn remaining_count_runs_down_and_deletes_the_order() {
    let mut g = base();
    owner("alice.test", T0);
    g.create_order("coffee".into(), U128(Y), acc("bob.test"), 3600, Some(U64(T0)), Some(2), "x".into());
    run_order(&mut g, T0);
    assert_eq!(g.get_orders(acc("alice.test"))[0].remaining, Some(1));
    run_order(&mut g, T0 + HOUR_NS);
    assert!(g.get_orders(acc("alice.test")).is_empty());
    assert_eq!(near_balance(&g), 8 * Y);
    env_as("anyone.test", None, 0, T0 + 2 * HOUR_NS);
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
}

/// One fresh world per case (each test runs in its own thread, so the mocked storage is not shared).
fn blocked_case(setup: &dyn Fn(&mut Guard)) {
    let mut g = order_world();
    setup(&mut g);
    let before = near_balance(&g);
    let receipts = g.get_receipts(acc("alice.test")).len();
    env_as("anyone.test", None, 0, T0);
    assert!(g.due_orders(0, 10).is_empty());
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
    assert_eq!(near_balance(&g), before);
    assert_eq!(g.get_orders(acc("alice.test"))[0].next_due_ns.0, T0);
    assert_eq!(g.get_receipts(acc("alice.test")).len(), receipts);
}

#[test]
fn blocked_order_frozen() {
    blocked_case(&|g| {
        owner("alice.test", T0);
        g.freeze();
    });
}

#[test]
fn blocked_order_pocket_paused() {
    blocked_case(&|g| {
        owner("alice.test", T0);
        g.pause_pocket("rent".into());
    });
}

#[test]
fn blocked_order_recipient_no_longer_allowed() {
    blocked_case(&|g| {
        owner("alice.test", T0);
        let mut c = cfg("rent", None);
        c.allowed_recipients = vec![acc("someone-else.test")];
        g.update_pocket(c);
    });
}

#[test]
fn blocked_order_over_the_pocket_cap() {
    blocked_case(&|g| {
        owner("alice.test", T0);
        let mut c = cfg("rent", None);
        c.per_payment_cap = U128(Y / 2);
        c.daily_cap = U128(Y / 2);
        g.update_pocket(c);
    });
}

#[test]
fn blocked_order_pocket_expired() {
    blocked_case(&|g| {
        owner("alice.test", T0 - 10);
        let mut c = cfg("rent", None);
        c.expires_at = Some(U64(T0 - 5));
        g.update_pocket(c);
    });
}

#[test]
fn blocked_order_vault_empty() {
    blocked_case(&|g| {
        owner("alice.test", T0);
        let _ = g.withdraw("near".into(), None);
    });
}

#[test]
fn order_uses_the_pockets_daily_cap() {
    let mut g = base();
    owner("alice.test", T0);
    g.create_order("coffee".into(), U128(Y), acc("bob.test"), 3600, Some(U64(T0)), None, "x".into());
    for _ in 0..3 {
        spend(&mut g, Y, "bob.test", T0); // uses the whole 3 NEAR day
    }
    env_as("anyone.test", None, 0, T0 + 10);
    assert!(g.due_orders(0, 10).is_empty());
    assert!(panics(|| {
        let _ = g.execute_order(acc("alice.test"), 1);
    }));
    // next day it works again
    run_order(&mut g, T0 + DAY_NS + 10);
    assert_eq!(near_balance(&g), 6 * Y);
}

#[test]
fn order_limits() {
    let mut g = base();
    let mk = |g: &mut Guard, interval: u64, amount: u128, rcpt: &str, remaining: Option<u32>, memo: &str| {
        owner("alice.test", T0);
        g.create_order("coffee".into(), U128(amount), acc(rcpt), interval, None, remaining, memo.into())
    };
    assert!(panics(|| {
        mk(&mut g, 3599, Y, "bob.test", None, "");
    }));
    assert!(panics(|| {
        mk(&mut g, MAX_INTERVAL_SECONDS + 1, Y, "bob.test", None, "");
    }));
    assert!(panics(|| {
        mk(&mut g, 3600, 0, "bob.test", None, "");
    }));
    assert!(panics(|| {
        mk(&mut g, 3600, Y + 1, "bob.test", None, ""); // over the pocket's per-payment cap
    }));
    assert!(panics(|| {
        mk(&mut g, 3600, Y, "guard.test", None, "");
    }));
    assert!(panics(|| {
        mk(&mut g, 3600, Y, "bob.test", Some(0), "");
    }));
    assert!(panics(|| {
        mk(&mut g, 3600, Y, "bob.test", None, &"m".repeat(141));
    }));
    owner("alice.test", T0);
    assert!(panics(|| {
        g.create_order("nope".into(), U128(Y), acc("bob.test"), 3600, None, None, "".into());
    }));
    for _ in 0..MAX_ORDERS {
        mk(&mut g, 3600, 1, "bob.test", None, &"m".repeat(140));
    }
    assert!(panics(|| {
        mk(&mut g, 3600, 1, "bob.test", None, ""); // the 21st
    }));
    owner("alice.test", T0);
    g.cancel_order(1);
    assert_eq!(g.get_orders(acc("alice.test")).len(), 19);
    mk(&mut g, 3600, 1, "bob.test", None, "");
    owner("alice.test", T0);
    assert!(panics(|| g.cancel_order(9999)));
}

#[test]
fn due_orders_pages_across_owners() {
    let mut g = guard();
    for who in ["a1.test", "a2.test", "a3.test"] {
        env_as(who, None, STORAGE_DEPOSIT + 5 * Y, T0);
        g.open_vault();
        owner(who, T0);
        g.create_pocket(cfg("p", None));
        owner(who, T0);
        g.create_order("p".into(), U128(1), acc("bob.test"), 3600, Some(U64(T0)), None, "".into());
    }
    env_as("keeper.test", None, 0, T0);
    assert_eq!(g.due_orders(0, 10).len(), 3);
    assert_eq!(g.due_orders(0, 1).len(), 1);
    assert_eq!(g.due_orders(1, 1)[0].owner, acc("a2.test"));
    assert_eq!(g.due_orders(2, 100).len(), 1);
    assert!(g.due_orders(3, 10).is_empty());
    assert!(g.due_orders(u32::MAX, u32::MAX).is_empty());
}

// ---------------------------------------------------------------- withdraw, freeze, close

#[test]
fn withdraw_works_also_when_frozen() {
    let mut g = base();
    owner("alice.test", T0);
    g.freeze();
    assert!(g.get_vault(acc("alice.test")).unwrap().frozen);
    assert!(get_logs().iter().any(|l| l.contains("\"event\":\"frozen\"")));
    owner("alice.test", T0);
    let _ = g.withdraw("near".into(), Some(U128(3 * Y)));
    assert_eq!(near_balance(&g), 7 * Y);
    owner("alice.test", T0);
    let _ = g.withdraw("near".into(), None);
    assert_eq!(near_balance(&g), 0);
    let r = g.get_receipts(acc("alice.test"));
    assert_eq!(r.len(), 2);
    assert_eq!(r[1].kind, Kind::Withdraw);
    assert_eq!(r[1].recipient, acc("alice.test"));
    owner("alice.test", T0);
    assert!(panics(|| {
        let _ = g.withdraw("near".into(), None); // nothing left
    }));
    owner("alice.test", T0);
    assert!(panics(|| {
        let _ = g.withdraw("near".into(), Some(U128(1)));
    }));
}

#[test]
fn close_vault_refunds_and_keeps_the_owner_list_consistent() {
    let mut g = guard();
    for who in ["a1.test", "a2.test", "a3.test"] {
        env_as(who, None, STORAGE_DEPOSIT + Y, T0);
        g.open_vault();
    }
    owner("a1.test", T0);
    assert!(panics(|| {
        let _ = g.close_vault(); // still holds 1 NEAR
    }));
    owner("a1.test", T0);
    let _ = g.withdraw("near".into(), None);
    // in flight: refused until settled
    owner("a1.test", T0);
    assert!(panics(|| {
        let _ = g.close_vault();
    }));
    settle_env(PromiseResult::Successful(vec![]), T0);
    g.on_payout(Settle {
        owner: acc("a1.test"),
        token: "near".into(),
        amount: U128(Y),
        receipt_id: 0,
        pocket: None,
        window_start: U64(0),
        order_before: None,
    });
    owner("a1.test", T0);
    let _ = g.close_vault();
    assert!(g.get_vault(acc("a1.test")).is_none());
    assert_eq!(g.owners_count(), 2);
    assert_eq!(g.load(&acc("a3.test")).owner_index, 0); // a3 moved into slot 0
    assert_eq!(g.load(&acc("a2.test")).owner_index, 1);
    assert!(get_logs().iter().any(|l| l.contains("vault_closed")));
    // a closed account can open a new vault
    env_as("a1.test", None, STORAGE_DEPOSIT, T0);
    g.open_vault();
    assert_eq!(g.owners_count(), 3);
    // closing without any vault
    owner("nobody.test", T0);
    assert!(panics(|| {
        let _ = g.close_vault();
    }));
}

// ---------------------------------------------------------------- settlement callback

#[test]
fn failed_spend_is_put_back() {
    let mut g = base();
    spend(&mut g, Y, "bob.test", T0);
    assert_eq!(near_balance(&g), 9 * Y);
    settle_env(PromiseResult::Failed, T0);
    g.on_payout(Settle {
        owner: acc("alice.test"),
        token: "near".into(),
        amount: U128(Y),
        receipt_id: 0,
        pocket: Some("coffee".into()),
        window_start: U64(T0),
        order_before: None,
    });
    assert_eq!(near_balance(&g), 10 * Y);
    assert_eq!(pocket(&g, "coffee").spent.0, 0);
    let v = g.get_vault(acc("alice.test")).unwrap();
    assert_eq!(v.pending_out, 0);
    assert!(!g.get_receipts(acc("alice.test"))[0].ok);
    assert!(get_logs().iter().any(|l| l.contains("payout_failed")));
}

#[test]
fn settled_spend_stays_spent_and_a_new_window_is_not_touched() {
    let mut g = base();
    spend(&mut g, Y, "bob.test", T0);
    settle_env(PromiseResult::Successful(vec![]), T0);
    let s = Settle {
        owner: acc("alice.test"),
        token: "near".into(),
        amount: U128(Y),
        receipt_id: 0,
        pocket: Some("coffee".into()),
        window_start: U64(T0),
        order_before: None,
    };
    g.on_payout(s.clone());
    assert_eq!(near_balance(&g), 9 * Y);
    assert_eq!(pocket(&g, "coffee").spent.0, Y);
    assert!(g.get_receipts(acc("alice.test"))[0].ok);
    assert_eq!(g.get_vault(acc("alice.test")).unwrap().pending_out, 0);
    // a failure that settles after the window rolled over restores the balance but not the new window's spend
    spend(&mut g, Y, "bob.test", T0 + DAY_NS + 5);
    settle_env(PromiseResult::Failed, T0 + DAY_NS + 6);
    let mut late = s;
    late.receipt_id = 99; // not in the ring: ignored
    g.on_payout(late);
    assert_eq!(near_balance(&g), 9 * Y); // 8 after the second spend, +1 restored
    assert_eq!(pocket(&g, "coffee").spent.0, Y); // new window untouched (window_start differs)
}

#[test]
fn failed_order_payment_restores_schedule_and_count() {
    let mut g = base();
    owner("alice.test", T0);
    g.create_order("coffee".into(), U128(Y), acc("bob.test"), 3600, Some(U64(T0)), Some(1), "x".into());
    let before = g.get_orders(acc("alice.test"))[0].clone();
    run_order(&mut g, T0 + 10);
    assert!(g.get_orders(acc("alice.test")).is_empty()); // deleted at zero
    settle_env(PromiseResult::Failed, T0 + 11);
    g.on_payout(Settle {
        owner: acc("alice.test"),
        token: "near".into(),
        amount: U128(Y),
        receipt_id: 0,
        pocket: Some("coffee".into()),
        window_start: U64(T0 + 10),
        order_before: Some(before.clone()),
    });
    let o = g.get_orders(acc("alice.test"));
    assert_eq!(o.len(), 1);
    assert_eq!(o[0].next_due_ns.0, T0);
    assert_eq!(o[0].remaining, Some(1));
    assert_eq!(near_balance(&g), 10 * Y);
    // and it can run again
    run_order(&mut g, T0 + 12);
    assert_eq!(near_balance(&g), 9 * Y);
}

#[test]
fn failed_ft_withdraw_and_approval_are_put_back() {
    let mut g = base();
    env_as("usdc.test", None, 0, T0);
    g.ft_on_transfer(acc("alice.test"), U128(1000), String::new());
    owner("alice.test", T0);
    let _ = g.withdraw("usdc.test".into(), Some(U128(400)));
    assert_eq!(g.load(&acc("alice.test")).balance("usdc.test"), 600);
    settle_env(PromiseResult::Failed, T0);
    g.on_payout(Settle {
        owner: acc("alice.test"),
        token: "usdc.test".into(),
        amount: U128(400),
        receipt_id: 0,
        pocket: None,
        window_start: U64(0),
        order_before: None,
    });
    assert_eq!(g.load(&acc("alice.test")).balance("usdc.test"), 1000);
    assert!(get_logs().iter().any(|l| l.contains("payout_failed")));
}

// ---------------------------------------------------------------- receipts ring

#[test]
fn receipts_keep_the_last_fifty_in_order() {
    let mut g = base();
    owner("alice.test", T0);
    let mut c = cfg("coffee", Some(1));
    c.per_payment_cap = U128(10);
    c.daily_cap = U128(1_000_000);
    g.update_pocket(c);
    for i in 0..55u64 {
        spend(&mut g, 1, "bob.test", T0 + i);
    }
    let r = g.get_receipts(acc("alice.test"));
    assert_eq!(r.len(), MAX_RECEIPTS);
    assert_eq!(r[0].id, 5);
    assert_eq!(r[49].id, 54);
    assert!(r.windows(2).all(|w| w[0].id + 1 == w[1].id));
    assert_eq!(g.get_vault(acc("alice.test")).unwrap().receipts_total, 55);
    // failure of a receipt that has been overwritten does not touch the newer one in its slot
    settle_env(PromiseResult::Failed, T0 + 100);
    g.on_payout(Settle {
        owner: acc("alice.test"),
        token: "near".into(),
        amount: U128(1),
        receipt_id: 0,
        pocket: None,
        window_start: U64(0),
        order_before: None,
    });
    assert!(g.get_receipts(acc("alice.test")).iter().all(|r| r.ok));
}
