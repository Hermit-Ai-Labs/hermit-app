//! End-to-end in a local nearcore sandbox: the real insurance wasm, a real NEP-141 token that requires registration
//! (like USDC), real accounts and keys. Covers buying cover, funding, a claim, the AI review, the owner's decision and
//! the payout landing in the claimant's token balance.
use near_workspaces::types::NearToken;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const ONE: u128 = 1_000_000;

fn read(var: &str, default: &str) -> Vec<u8> {
    std::fs::read(std::env::var(var).unwrap_or_else(|_| default.into())).unwrap()
}

#[tokio::test]
async fn the_whole_story() {
    let w = near_workspaces::sandbox().await.unwrap();
    let owner = w.dev_create_account().await.unwrap();
    let reviewer = w.dev_create_account().await.unwrap();
    let alice = w.dev_create_account().await.unwrap();
    let mallory = w.dev_create_account().await.unwrap();

    let ft = w.dev_deploy(&read("FT_WASM", "../../guard/dist/test_ft.wasm")).await.unwrap();
    ft.call("new").args_json(json!({"owner_id": owner.id(), "total_supply": (1_000_000 * ONE).to_string()})).transact().await.unwrap().into_result().unwrap();
    let ins = w.dev_deploy(&read("INSURANCE_WASM", "../dist/insurance.wasm")).await.unwrap();
    ins.call("new").args_json(json!({"owner": owner.id(), "reviewer": reviewer.id(), "token": ft.id(), "price": ONE.to_string()}))
        .transact().await.unwrap().into_result().unwrap();

    // register everyone with the token, give alice 10
    for who in [ins.id(), alice.id(), mallory.id()] {
        owner.call(ft.id(), "storage_deposit").args_json(json!({"account_id": who, "registration_only": true}))
            .deposit(NearToken::from_millinear(10)).transact().await.unwrap().into_result().unwrap();
    }
    owner.call(ft.id(), "ft_transfer").args_json(json!({"receiver_id": alice.id(), "amount": (10 * ONE).to_string()}))
        .deposit(NearToken::from_yoctonear(1)).transact().await.unwrap().into_result().unwrap();

    let bal = |who: near_workspaces::AccountId| {
        let ft = ft.clone();
        async move { ft.view("ft_balance_of").args_json(json!({"account_id": who})).await.unwrap().json::<String>().unwrap().parse::<u128>().unwrap() }
    };
    let info = || { let ins = ins.clone(); async move { ins.view("info").await.unwrap().json::<Value>().unwrap() } };

    // alice buys one month for 1 USDC
    let r = alice.call(ft.id(), "ft_transfer_call").args_json(json!({"receiver_id": ins.id(), "amount": ONE.to_string(), "msg": "cover"}))
        .deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_success(), "{:?}", r.failures());
    assert_eq!(bal(alice.id().clone()).await, 9 * ONE);
    let cov: Value = ins.view("cover_of").args_json(json!({"account_id": alice.id()})).await.unwrap().json().unwrap();
    assert_eq!(cov["active"], true);

    // Hermit funds the pool with 50
    owner.call(ft.id(), "ft_transfer_call").args_json(json!({"receiver_id": ins.id(), "amount": (50 * ONE).to_string(), "msg": "fund"}))
        .deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap().into_result().unwrap();
    assert_eq!(info().await["pool"], (51 * ONE).to_string());

    // mallory has no cover: refused
    let ev = r#"{"kind":"swap","title":"Swap 20 USDC","result":"Swapped 200 USDC"}"#;
    let fp = hex::encode(Sha256::digest(ev.as_bytes()));
    let r = mallory.call(ins.id(), "file_claim").args_json(json!({"fp": fp, "evidence": ev, "loss": (20 * ONE).to_string(), "note": ""}))
        .deposit(NearToken::from_millinear(50)).max_gas().transact().await.unwrap();
    assert!(r.is_failure());

    // alice files with matching evidence
    let r = alice.call(ins.id(), "file_claim").args_json(json!({"fp": fp, "evidence": ev, "loss": (20 * ONE).to_string(), "note": "asked for 20"}))
        .deposit(NearToken::from_millinear(50)).max_gas().transact().await.unwrap();
    assert!(r.is_success(), "{:?}", r.failures());
    let id: u64 = r.json().unwrap();

    // the reviewer can't decide; a stranger can't review
    let r = reviewer.call(ins.id(), "decide").args_json(json!({"id": id, "approve": true, "award": (20 * ONE).to_string(), "reason": "x"}))
        .deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_failure());
    let r = mallory.call(ins.id(), "ai_review").args_json(json!({"id": id, "verdict": "approve", "reason": "x"})).transact().await.unwrap();
    assert!(r.is_failure());

    reviewer.call(ins.id(), "ai_review").args_json(json!({"id": id, "verdict": "approve", "reason": "The review showed 200; the user asked for 20."}))
        .transact().await.unwrap().into_result().unwrap();

    // the owner approves 18: paid straight to alice's token balance
    let r = owner.call(ins.id(), "decide").args_json(json!({"id": id, "approve": true, "award": (18 * ONE).to_string(), "reason": "AI prepared the wrong amount"}))
        .deposit(NearToken::from_yoctonear(1)).max_gas().transact().await.unwrap();
    assert!(r.is_success(), "{:?}", r.failures());
    assert_eq!(bal(alice.id().clone()).await, 27 * ONE);
    let c: Value = ins.view("get_claim").args_json(json!({"id": id})).await.unwrap().json().unwrap();
    assert_eq!(c["status"], "paid");
    assert_eq!(c["ai_verdict"], "approve");
    let i = info().await;
    assert_eq!((i["pool"].as_str().unwrap(), i["paid_out"].as_str().unwrap(), i["owed"].as_str().unwrap()),
               ((33 * ONE).to_string().as_str(), (18 * ONE).to_string().as_str(), "0"));

    // the same record can't be claimed twice
    let r = alice.call(ins.id(), "file_claim").args_json(json!({"fp": fp, "evidence": ev, "loss": "1", "note": ""}))
        .deposit(NearToken::from_millinear(50)).max_gas().transact().await.unwrap();
    assert!(r.is_failure());

    println!("insurance storage: {} bytes", ins.view_account().await.unwrap().storage_usage);
}
