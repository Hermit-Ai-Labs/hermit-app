//! End-to-end against a local nearcore sandbox, with the real optimized wasm (dist/blackbox.wasm) and real access keys.
use near_workspaces::types::{AccessKey, KeyType, NearToken, SecretKey};
use near_workspaces::Account;
use serde_json::{json, Value};

const Y: u128 = 1_000_000_000_000_000_000_000_000;
const W: &str = "3cd5cb7b3511d03872a80ec01d8ae95d7f6444af66549c78621d39d8b23c9fca";
const P: &str = "1111111111111111111111111111111111111111111111111111111111111111";

fn model(id: &str) -> Value {
    json!({"model": {"id": id, "name": "Hermit 1.3", "revision": "25ae0154b7a3861a54abda03beb2663a28829566",
        "weights_sha256": W, "pin_digest": P, "bytes": "2765806707", "scores": "1801 of 1801",
        "url": "https://huggingface.co/aiquantgod/Hermit-1.3-4B-MLX-5bit"}})
}

#[tokio::test]
async fn the_whole_story() {
    let path = std::env::var("BLACKBOX_WASM").unwrap_or_else(|_| "../dist/blackbox.wasm".into());
    let wasm = std::fs::read(&path).unwrap();
    let w = near_workspaces::sandbox().await.unwrap();
    let owner = w.dev_create_account().await.unwrap();
    let alice = w.dev_create_account().await.unwrap();
    let c = w.dev_deploy(&wasm).await.unwrap();
    c.call("new").args_json(json!({"owner": owner.id()})).transact().await.unwrap().into_result().unwrap();

    // the owner publishes; the hash can't be published twice
    let r = owner.call(c.id(), "publish_model").args_json(model("a/b")).deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_success(), "{:?}", r.failures());
    assert!(r.logs().iter().any(|l| l.contains("model_published")));
    let r = owner.call(c.id(), "publish_model").args_json(model("a/b")).deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_failure());

    // a stranger can't publish
    let r = alice.call(c.id(), "publish_model").args_json(model("x/y")).deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_failure());

    let ok: bool = c.view("check_model").args_json(json!({"id": "a/b", "weights_sha256": W, "pin_digest": P})).await.unwrap().json().unwrap();
    assert!(ok);

    // alice adds a function-call key for `record` only, as the app does, and records with it: no Face ID, no deposit
    let sk = SecretKey::from_random(KeyType::ED25519);
    alice.batch(alice.id()).add_key(sk.public_key(), AccessKey::function_call_access(c.id(), &["record"], Some(NearToken::from_yoctonear(Y / 4))))
        .transact().await.unwrap().into_result().unwrap();
    let rec = Account::from_secret_key(alice.id().clone(), sk, &w);
    let r = rec.call(c.id(), "record").args_json(json!({"fp": "ab".repeat(32), "kind": "swap", "model": "a/b"})).transact().await.unwrap();
    assert!(r.is_success(), "{:?}", r.failures());
    let log = r.logs().join("\n");
    assert!(log.contains(&"ab".repeat(32)) && log.contains(alice.id().as_str()));
    println!("record gas burnt: {} Tgas", r.total_gas_burnt.as_tgas());

    // that key can't do anything else: not publish (can't attach the 1 yocto), not another method, not a transfer
    let r = rec.call(c.id(), "publish_model").args_json(model("k/k")).deposit(NearToken::from_yoctonear(1)).transact().await;
    assert!(r.is_err() || r.unwrap().is_failure());
    let r = rec.call(c.id(), "set_owner").args_json(json!({"owner": alice.id()})).transact().await;
    assert!(r.is_err() || r.unwrap().is_failure());
    assert!(rec.transfer_near(owner.id(), NearToken::from_yoctonear(1)).await.map(|r| r.is_failure()).unwrap_or(true));

    // records don't grow storage
    let before = c.view_account().await.unwrap().storage_usage;
    for i in 0..5u8 {
        rec.call(c.id(), "record").args_json(json!({"fp": format!("{:02x}", i).repeat(32), "kind": "send"})).transact().await.unwrap().into_result().unwrap();
    }
    assert_eq!(c.view_account().await.unwrap().storage_usage, before);
    let info: Value = c.view("info").await.unwrap().json().unwrap();
    assert_eq!(info["records"], "6");
    assert_eq!(info["models"], 1);

    // revoke keeps the entry, check fails
    owner.call(c.id(), "revoke_model").args_json(json!({"id": "a/b", "reason": "test"})).deposit(NearToken::from_yoctonear(1)).transact().await.unwrap().into_result().unwrap();
    let ok: bool = c.view("check_model").args_json(json!({"id": "a/b", "weights_sha256": W, "pin_digest": P})).await.unwrap().json().unwrap();
    assert!(!ok);
    println!("storage after one model: {} bytes", c.view_account().await.unwrap().storage_usage);
}
