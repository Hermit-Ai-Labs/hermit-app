//! Hermit Black Box, on NEAR mainnet as `hermit-blackbox.near`.
//!
//! Two public records that nobody, us included, can quietly rewrite:
//!
//! 1. **Model registry.** For every Hermit model we ship: the Hugging Face revision, the SHA-256 of the weights, a digest
//!    of every file the app pins, the size and the test scores. Entries are append-only. A published hash can never be
//!    changed; a bad release can only be marked revoked, with a reason, and the old entry stays readable. The app
//!    compares the model it runs against this registry.
//! 2. **Flight recorder.** When you approve a money move the assistant prepared, the app can write a fingerprint of the
//!    decision: a SHA-256 of what the model proposed, what the review showed and what happened, salted on the device.
//!    Only the fingerprint goes on chain, never the chat, the amounts or the addresses. It's written as an event log,
//!    not stored, so it costs the caller gas only and the contract never grows. The device keeps the text behind each
//!    fingerprint, so you can later prove exactly what the AI did, and anyone can check it against the chain.
//!
//! Owner methods need a 1-yoctoNEAR deposit, so a function-call access key (which can't attach one) can only ever call
//! `record`.

use near_sdk::json_types::U64;
use near_sdk::serde_json::{json, Value};
use near_sdk::store::{LookupMap, Vector};
use near_sdk::{env, near, require, AccountId, PanicOnDefault};

pub const VERSION: &str = "1.0.0";
const STANDARD: &str = "hermit-blackbox";

#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq)]
pub struct Model {
    /// The id the app uses, e.g. `aiquantgod/Hermit-1.3-4B-MLX-5bit`.
    pub id: String,
    /// What people call it, e.g. `Hermit 1.3`.
    pub name: String,
    /// Hugging Face commit (40 hex).
    pub revision: String,
    /// SHA-256 of `model.safetensors` (64 hex).
    pub weights_sha256: String,
    /// SHA-256 over every pinned file, one line each, sorted by path: `path\tsize\tsha256\n`.
    pub pin_digest: String,
    /// Size of the weights in bytes.
    pub bytes: U64,
    /// Short summary of the held-out test scores.
    pub scores: String,
    /// Model card or results page.
    pub url: String,
    pub published_at_ns: U64,
    pub published_by: AccountId,
    pub revoked: bool,
    pub revoke_reason: Option<String>,
}

#[near(serializers = [json])]
pub struct NewModel {
    pub id: String,
    pub name: String,
    pub revision: String,
    pub weights_sha256: String,
    pub pin_digest: String,
    pub bytes: U64,
    pub scores: String,
    pub url: String,
}

#[near(serializers = [json])]
pub struct Info {
    pub version: String,
    pub owner: AccountId,
    pub models: u32,
    pub records: U64,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct BlackBox {
    owner: AccountId,
    ids: Vector<String>,
    models: LookupMap<String, Model>,
    records: u64,
}

fn emit(event: &str, data: Value) {
    let e = json!({ "standard": STANDARD, "version": VERSION, "event": event, "data": [data] });
    env::log_str(&format!("EVENT_JSON:{}", e));
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn plain(s: &str, max: usize, what: &str) {
    require!(!s.is_empty() && s.len() <= max, format!("{what} must be 1 to {max} characters"));
    require!(!s.chars().any(|c| c.is_control()), format!("{what} has a control character"));
}

fn slug(s: &str, max: usize, what: &str) {
    require!(!s.is_empty() && s.len() <= max, format!("{what} must be 1 to {max} characters"));
    require!(
        s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:".contains(&b)),
        format!("{what} may only use letters, digits and - _ . / :")
    );
}

#[near]
impl BlackBox {
    #[init]
    pub fn new(owner: AccountId) -> Self {
        Self { owner, ids: Vector::new(b"i".to_vec()), models: LookupMap::new(b"m".to_vec()), records: 0 }
    }

    fn only_owner(&self) {
        near_sdk::assert_one_yocto();
        require!(env::predecessor_account_id() == self.owner, "Only the owner can do this");
    }

    // ---------- model registry ----------

    /// Publish a model. Append-only: an id can be published once, and its hashes never change.
    #[payable]
    pub fn publish_model(&mut self, model: NewModel) -> Model {
        self.only_owner();
        slug(&model.id, 96, "id");
        plain(&model.name, 48, "name");
        require!(is_hex(&model.revision, 40), "revision must be 40 lowercase hex characters");
        require!(is_hex(&model.weights_sha256, 64), "weights_sha256 must be 64 lowercase hex characters");
        require!(is_hex(&model.pin_digest, 64), "pin_digest must be 64 lowercase hex characters");
        require!(model.bytes.0 > 0, "bytes must be more than 0");
        plain(&model.scores, 600, "scores");
        plain(&model.url, 200, "url");
        require!(model.url.starts_with("https://"), "url must start with https://");
        require!(!self.models.contains_key(&model.id), "This id is already published; hashes can't be changed");
        let m = Model {
            id: model.id,
            name: model.name,
            revision: model.revision,
            weights_sha256: model.weights_sha256,
            pin_digest: model.pin_digest,
            bytes: model.bytes,
            scores: model.scores,
            url: model.url,
            published_at_ns: U64(env::block_timestamp()),
            published_by: env::predecessor_account_id(),
            revoked: false,
            revoke_reason: None,
        };
        self.ids.push(m.id.clone());
        self.models.insert(m.id.clone(), m.clone());
        emit("model_published", json!({ "id": m.id, "name": m.name, "revision": m.revision,
            "weights_sha256": m.weights_sha256, "pin_digest": m.pin_digest }));
        m
    }

    /// Mark a model as revoked. The entry and its hashes stay; the app stops trusting it.
    #[payable]
    pub fn revoke_model(&mut self, id: String, reason: String) {
        self.only_owner();
        plain(&reason, 200, "reason");
        let mut m = self.models.get(&id).cloned().unwrap_or_else(|| env::panic_str("No model with this id"));
        require!(!m.revoked, "Already revoked");
        m.revoked = true;
        m.revoke_reason = Some(reason.clone());
        self.models.insert(id.clone(), m);
        emit("model_revoked", json!({ "id": id, "reason": reason }));
    }

    #[payable]
    pub fn set_owner(&mut self, owner: AccountId) {
        self.only_owner();
        emit("owner_changed", json!({ "from": self.owner, "to": owner }));
        self.owner = owner;
    }

    pub fn get_model(&self, id: String) -> Option<Model> {
        self.models.get(&id).cloned()
    }

    /// Models in the order they were published.
    pub fn models(&self, from_index: Option<u32>, limit: Option<u32>) -> Vec<Model> {
        let from = from_index.unwrap_or(0);
        let limit = limit.unwrap_or(50).min(100);
        (from..self.ids.len().min(from.saturating_add(limit)))
            .filter_map(|i| self.ids.get(i).and_then(|id| self.models.get(id)).cloned())
            .collect()
    }

    /// True only if this id is published, not revoked, and both hashes match.
    pub fn check_model(&self, id: String, weights_sha256: String, pin_digest: String) -> bool {
        self.models
            .get(&id)
            .map(|m| !m.revoked && m.weights_sha256 == weights_sha256 && m.pin_digest == pin_digest)
            .unwrap_or(false)
    }

    // ---------- flight recorder ----------

    /// Write the fingerprint of one money decision. Anyone can call it, and it only ever records under the caller's
    /// account. Nothing is stored except the running count; the record lives in the receipt's event log.
    pub fn record(&mut self, fp: String, kind: String, model: Option<String>) -> U64 {
        require!(is_hex(&fp, 64), "fp must be a SHA-256 as 64 lowercase hex characters");
        slug(&kind, 32, "kind");
        if let Some(m) = &model {
            slug(m, 96, "model");
        }
        self.records += 1;
        emit("record", json!({ "by": env::predecessor_account_id(), "fp": fp, "kind": kind, "model": model,
            "n": U64(self.records), "at_ns": U64(env::block_timestamp()) }));
        U64(self.records)
    }

    pub fn info(&self) -> Info {
        Info { version: VERSION.into(), owner: self.owner.clone(), models: self.ids.len(), records: U64(self.records) }
    }
}

#[cfg(test)]
mod tests;
