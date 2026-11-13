use super::*;
use near_sdk::test_utils::{get_logs, VMContextBuilder};
use near_sdk::testing_env;

const USDC: &str = "usdc.near";
const ONE: u128 = 1_000_000;
const DAY: u64 = 86_400_000_000_000;
const T0: u64 = 1_800_000_000_000_000_000;

fn acc(s: &str) -> AccountId {
    s.parse().unwrap()
}

fn ctx(who: &str, yocto: u128, now: u64) {
    testing_env!(VMContextBuilder::new()
        .current_account_id(acc("hermit-insurance.near"))
        .predecessor_account_id(acc(who))
        .attached_deposit(NearToken::from_yoctonear(yocto))
        .block_timestamp(now)
        .build());
}

fn setup() -> Insurance {
    ctx("owner.near", 0, T0);
    Insurance::new(acc("owner.near"), acc("reviewer.near"), acc(USDC), U128(ONE))
}

fn buy(c: &mut Insurance, who: &str, amount: u128, now: u64) -> U128 {
    ctx(USDC, 0, now);
    c.ft_on_transfer(acc(who), U128(amount), "cover".into())
}

fn evidence(n: u8) -> (String, String) {
    let e = format!("{{\"kind\":\"swap\",\"title\":\"Swap 20 USDC\",\"n\":{n}}}");
    (hex(&env::sha256(e.as_bytes())), e)
}

fn file(c: &mut Insurance, who: &str, n: u8, now: u64) -> u64 {
    let (fp, e) = evidence(n);
    ctx(who, CLAIM_DEPOSIT, now);
    c.file_claim(fp, e, U128(20 * ONE), "It swapped 200 instead of 20".into())
}

#[test]
fn cover_buys_thirty_days_per_dollar_and_returns_change() {
    let mut c = setup();
    assert_eq!(buy(&mut c, "alice.near", ONE * 2 + 5, T0), U128(5), "change comes back");
    let cov = c.cover_of(acc("alice.near"));
    assert!(cov.active);
    assert_eq!(cov.expires_ns.0, T0 + 2 * PERIOD_NS);
    assert_eq!(c.info().pool, U128(2 * ONE));
    assert_eq!(c.info().members, 1);
    // buying again early extends from the old expiry
    buy(&mut c, "alice.near", ONE, T0 + DAY);
    assert_eq!(c.cover_of(acc("alice.near")).expires_ns.0, T0 + 3 * PERIOD_NS);
    assert_eq!(c.info().members, 1);
}

#[test]
fn cover_expires() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    ctx("alice.near", 0, T0 + PERIOD_NS + 1);
    assert!(!c.cover_of(acc("alice.near")).active);
}

#[test]
fn other_tokens_and_unknown_msgs_are_returned() {
    let mut c = setup();
    ctx("fake-usdc.near", 0, T0);
    assert_eq!(c.ft_on_transfer(acc("alice.near"), U128(ONE), "cover".into()), U128(ONE));
    ctx(USDC, 0, T0);
    assert_eq!(c.ft_on_transfer(acc("alice.near"), U128(ONE), "hello".into()), U128(ONE));
    assert_eq!(c.ft_on_transfer(acc("alice.near"), U128(ONE / 2), "cover".into()), U128(ONE / 2), "less than one period");
    assert_eq!(c.info().pool, U128(0));
}

#[test]
fn anyone_can_fund_the_pool() {
    let mut c = setup();
    ctx(USDC, 0, T0);
    assert_eq!(c.ft_on_transfer(acc("hermit.near"), U128(50 * ONE), "fund".into()), U128(0));
    assert_eq!(c.info().pool, U128(50 * ONE));
}

#[test]
fn file_review_approve_pays_from_the_pool() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    ctx(USDC, 0, T0);
    c.ft_on_transfer(acc("hermit.near"), U128(50 * ONE), "fund".into());
    let id = file(&mut c, "alice.near", 1, T0 + DAY);
    ctx("reviewer.near", 0, T0 + DAY);
    c.ai_review(id, "approve".into(), "The review showed 200 USDC; the user asked for 20.".into());
    assert_eq!(c.get_claim(id).unwrap().ai_verdict.as_deref(), Some("approve"));
    ctx("owner.near", 1, T0 + DAY);
    assert!(c.decide(id, true, U128(20 * ONE), "AI prepared the wrong amount".into()).is_some());
    assert_eq!(c.info().pool, U128(31 * ONE), "51 in, 20 on its way");
    assert_eq!(c.get_claim(id).unwrap().pending, U128(20 * ONE));
}

#[test]
fn approved_claim_larger_than_pool_is_paid_as_it_refills() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 1, T0);
    c.decide(id, true, U128(20 * ONE), "ok".into());
    let cl = c.get_claim(id).unwrap();
    assert_eq!(cl.pending, U128(ONE), "only the 1 USDC in the pool goes out now");
    assert_eq!(c.info().pool, U128(0));
    assert_eq!(c.info().owed, U128(20 * ONE));
    // nothing more to pay until the pool refills
    assert!(c.settle(id).is_none());
    ctx(USDC, 0, T0);
    c.ft_on_transfer(acc("hermit.near"), U128(100 * ONE), "fund".into());
    assert!(c.settle(id).is_some());
    assert_eq!(c.get_claim(id).unwrap().pending, U128(20 * ONE));
    assert_eq!(c.info().pool, U128(81 * ONE));
}

#[test]
fn rejected_claim_takes_nothing() {
    let mut c = setup();
    buy(&mut c, "alice.near", 5 * ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 1, T0);
    assert!(c.decide(id, false, U128(0), "Market loss, not an AI mistake".into()).is_none());
    assert_eq!(c.get_claim(id).unwrap().status, "rejected");
    assert_eq!(c.info().pool, U128(5 * ONE));
    assert!(get_logs().iter().any(|l| l.contains("claim_rejected")));
}

#[test]
#[should_panic(expected = "evidence doesn't match the fingerprint")]
fn evidence_must_hash_to_the_fingerprint() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let (fp, _) = evidence(1);
    let (_, other) = evidence(2);
    ctx("alice.near", CLAIM_DEPOSIT, T0);
    c.file_claim(fp, other, U128(ONE), "".into());
}

#[test]
#[should_panic(expected = "No active cover")]
fn no_cover_no_claim() {
    let mut c = setup();
    file(&mut c, "bob.near", 1, T0);
}

#[test]
#[should_panic(expected = "No active cover")]
fn expired_cover_no_claim() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    file(&mut c, "alice.near", 1, T0 + PERIOD_NS + 1);
}

#[test]
#[should_panic(expected = "Attach 0.05 NEAR")]
fn claim_needs_the_deposit() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let (fp, e) = evidence(1);
    ctx("alice.near", 0, T0);
    c.file_claim(fp, e, U128(ONE), "".into());
}

#[test]
#[should_panic(expected = "already has a claim")]
fn one_claim_per_record() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    file(&mut c, "alice.near", 1, T0);
    file(&mut c, "alice.near", 1, T0);
}

#[test]
#[should_panic(expected = "Only the owner")]
fn reviewer_cannot_decide() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("reviewer.near", 1, T0);
    c.decide(id, true, U128(ONE), "x".into());
}

#[test]
#[should_panic(expected = "Only the reviewer")]
fn stranger_cannot_review() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("mallory.near", 0, T0);
    c.ai_review(id, "approve".into(), "x".into());
}

#[test]
#[should_panic(expected = "Requires attached deposit of exactly 1 yoctoNEAR")]
fn decide_needs_one_yocto() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 0, T0);
    c.decide(id, false, U128(0), "x".into());
}

#[test]
#[should_panic(expected = "already decided")]
fn decide_once() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 1, T0);
    c.decide(id, false, U128(0), "x".into());
    c.decide(id, true, U128(ONE), "y".into());
}

#[test]
#[should_panic(expected = "Only an approved claim is paid")]
fn settle_refuses_unapproved() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    c.settle(id);
}

#[test]
fn failed_payout_goes_back_to_the_pool() {
    let mut c = setup();
    buy(&mut c, "alice.near", 10 * ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 1, T0);
    c.decide(id, true, U128(4 * ONE), "ok".into());
    assert_eq!(c.info().pool, U128(6 * ONE));
    testing_env!(
        VMContextBuilder::new().current_account_id(acc("hermit-insurance.near")).predecessor_account_id(acc("hermit-insurance.near")).build(),
        near_sdk::test_vm_config(),
        near_sdk::RuntimeFeesConfig::test(),
        Default::default(),
        vec![PromiseResult::Failed]
    );
    c.on_paid(id, U128(4 * ONE));
    assert_eq!(c.info().pool, U128(10 * ONE));
    let cl = c.get_claim(id).unwrap();
    assert_eq!((cl.pending, cl.paid, cl.status.as_str()), (U128(0), U128(0), "approved"));
}

#[test]
fn successful_payout_marks_paid() {
    let mut c = setup();
    buy(&mut c, "alice.near", 10 * ONE, T0);
    let id = file(&mut c, "alice.near", 1, T0);
    ctx("owner.near", 1, T0);
    c.decide(id, true, U128(4 * ONE), "ok".into());
    testing_env!(
        VMContextBuilder::new().current_account_id(acc("hermit-insurance.near")).predecessor_account_id(acc("hermit-insurance.near")).build(),
        near_sdk::test_vm_config(),
        near_sdk::RuntimeFeesConfig::test(),
        Default::default(),
        vec![PromiseResult::Successful(vec![])]
    );
    c.on_paid(id, U128(4 * ONE));
    let i = c.info();
    assert_eq!((i.paid_out, i.owed, i.pool), (U128(4 * ONE), U128(0), U128(6 * ONE)));
    assert_eq!(c.get_claim(id).unwrap().status, "paid");
}

#[test]
fn claims_list_newest_first() {
    let mut c = setup();
    buy(&mut c, "alice.near", ONE, T0);
    for n in 0..3 {
        file(&mut c, "alice.near", n, T0);
    }
    let ids: Vec<u64> = c.claims(None, None).iter().map(|c| c.id).collect();
    assert_eq!(ids, vec![2, 1, 0]);
}
