use super::*;
use near_sdk::test_utils::{get_logs, VMContextBuilder};
use near_sdk::{testing_env, NearToken};

fn acc(s: &str) -> AccountId {
    s.parse().unwrap()
}

fn ctx(who: &str, yocto: u128) {
    testing_env!(VMContextBuilder::new()
        .predecessor_account_id(acc(who))
        .attached_deposit(NearToken::from_yoctonear(yocto))
        .block_timestamp(1_700_000_000_000_000_000)
        .build());
}

const W: &str = "3cd5cb7b3511d03872a80ec01d8ae95d7f6444af66549c78621d39d8b23c9fca";
const P: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const REV: &str = "25ae0154b7a3861a54abda03beb2663a28829566";

fn model(id: &str) -> NewModel {
    NewModel {
        id: id.into(),
        name: "Hermit 1.3".into(),
        revision: REV.into(),
        weights_sha256: W.into(),
        pin_digest: P.into(),
        bytes: U64(2_765_806_707),
        scores: "1801 of 1801 never claim a move without a tool result".into(),
        url: "https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit".into(),
    }
}

fn setup() -> BlackBox {
    ctx("owner.near", 0);
    BlackBox::new(acc("owner.near"))
}

#[test]
fn publish_and_read() {
    let mut c = setup();
    ctx("owner.near", 1);
    let m = c.publish_model(model("aiquantgod/Hermit-1.3-4B-MLX-5bit"));
    assert_eq!(m.published_by, acc("owner.near"));
    assert!(!m.revoked);
    assert_eq!(c.get_model("aiquantgod/Hermit-1.3-4B-MLX-5bit".into()).unwrap(), m);
    assert_eq!(c.models(None, None).len(), 1);
    assert_eq!(c.info().models, 1);
    assert!(get_logs()[0].starts_with("EVENT_JSON:{"));
    assert!(get_logs()[0].contains("\"model_published\""));
}

#[test]
fn check_model_needs_both_hashes_and_not_revoked() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.publish_model(model("a/b"));
    assert!(c.check_model("a/b".into(), W.into(), P.into()));
    assert!(!c.check_model("a/b".into(), P.into(), P.into()));
    assert!(!c.check_model("a/b".into(), W.into(), W.into()));
    assert!(!c.check_model("nope".into(), W.into(), P.into()));
    c.revoke_model("a/b".into(), "bad release".into());
    assert!(!c.check_model("a/b".into(), W.into(), P.into()));
    let m = c.get_model("a/b".into()).unwrap();
    assert!(m.revoked);
    assert_eq!(m.weights_sha256, W, "a revoked entry keeps its hashes");
    assert_eq!(m.revoke_reason.as_deref(), Some("bad release"));
}

#[test]
#[should_panic(expected = "already published")]
fn hashes_can_never_change() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.publish_model(model("a/b"));
    let mut again = model("a/b");
    again.weights_sha256 = P.into();
    c.publish_model(again);
}

#[test]
#[should_panic(expected = "Only the owner")]
fn stranger_cannot_publish() {
    let mut c = setup();
    ctx("mallory.near", 1);
    c.publish_model(model("a/b"));
}

#[test]
#[should_panic(expected = "Requires attached deposit of exactly 1 yoctoNEAR")]
fn owner_methods_need_one_yocto() {
    let mut c = setup();
    ctx("owner.near", 0);
    c.publish_model(model("a/b"));
}

#[test]
#[should_panic(expected = "Only the owner")]
fn stranger_cannot_revoke() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.publish_model(model("a/b"));
    ctx("mallory.near", 1);
    c.revoke_model("a/b".into(), "x".into());
}

#[test]
#[should_panic(expected = "Already revoked")]
fn revoke_once() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.publish_model(model("a/b"));
    c.revoke_model("a/b".into(), "x".into());
    c.revoke_model("a/b".into(), "y".into());
}

#[test]
#[should_panic(expected = "weights_sha256 must be")]
fn rejects_bad_hash() {
    let mut c = setup();
    ctx("owner.near", 1);
    let mut m = model("a/b");
    m.weights_sha256 = W.to_uppercase();
    c.publish_model(m);
}

#[test]
#[should_panic(expected = "revision must be")]
fn rejects_bad_revision() {
    let mut c = setup();
    ctx("owner.near", 1);
    let mut m = model("a/b");
    m.revision = "main".into();
    c.publish_model(m);
}

#[test]
#[should_panic(expected = "url must start with https://")]
fn rejects_plain_http() {
    let mut c = setup();
    ctx("owner.near", 1);
    let mut m = model("a/b");
    m.url = "http://x.y".into();
    c.publish_model(m);
}

#[test]
#[should_panic(expected = "id may only use")]
fn rejects_odd_id() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.publish_model(model("a b"));
}

#[test]
fn set_owner_moves_control() {
    let mut c = setup();
    ctx("owner.near", 1);
    c.set_owner(acc("new.near"));
    assert_eq!(c.info().owner, acc("new.near"));
    ctx("new.near", 1);
    c.publish_model(model("a/b"));
}

#[test]
fn record_logs_fingerprint_and_counts() {
    let mut c = setup();
    ctx("alice.near", 0);
    let fp = "ab".repeat(32);
    assert_eq!(c.record(fp.clone(), "swap".into(), Some("aiquantgod/Hermit-1.3-4B-MLX-5bit".into())), U64(1));
    let log = &get_logs()[0];
    assert!(log.contains("\"record\"") && log.contains(&fp) && log.contains("alice.near") && log.contains("\"n\":\"1\""));
    ctx("bob.near", 0);
    assert_eq!(c.record("cd".repeat(32), "perp_order".into(), None), U64(2));
    assert_eq!(c.info().records, U64(2));
}

#[test]
#[should_panic(expected = "fp must be")]
fn record_rejects_non_hash() {
    let mut c = setup();
    ctx("alice.near", 0);
    c.record("send 5 NEAR to bob".into(), "send".into(), None);
}

#[test]
#[should_panic(expected = "kind may only use")]
fn record_rejects_odd_kind() {
    let mut c = setup();
    ctx("alice.near", 0);
    c.record("ab".repeat(32), "send money".into(), None);
}

#[test]
fn record_never_stores_per_call() {
    let mut c = setup();
    ctx("alice.near", 0);
    c.record("ab".repeat(32), "swap".into(), None);
    let before = env::storage_usage();
    for i in 0..20u8 {
        c.record(format!("{:02x}", i).repeat(32), "swap".into(), None);
    }
    assert_eq!(env::storage_usage(), before, "records live in logs, not storage");
}

#[test]
fn models_paginates_in_order() {
    let mut c = setup();
    ctx("owner.near", 1);
    for i in 0..5 {
        c.publish_model(model(&format!("m/{i}")));
    }
    let page = c.models(Some(1), Some(2));
    assert_eq!(page.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), vec!["m/1", "m/2"]);
    assert_eq!(c.models(Some(4), Some(10)).len(), 1);
    assert_eq!(c.models(Some(9), None).len(), 0);
}
