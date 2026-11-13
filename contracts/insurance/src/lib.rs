//! Hermit AI insurance, on NEAR mainnet as `hermit-insurance.near`.
//!
//! An opt-in pool that pays people back when the AI made a mistake that cost them money.
//!
//! - **Cover.** Send USDC to this contract with `ft_transfer_call(msg: "cover")`: each `price` (1 USDC) buys 30 days.
//!   All of it goes into the pool.
//! - **Funding.** Anyone can add to the pool with `msg: "fund"`.
//! - **Claims.** While covered, file a claim with the Black Box fingerprint of the move (hermit-blackbox.near) and the
//!   text behind it. The contract checks `sha256(evidence) == fp`, so the evidence is exactly what was recorded.
//! - **Review.** The AI reviewer account writes its verdict and reason on chain. The owner decides; only an approved
//!   claim can take money out of the pool, and there is no other way out: no admin withdraw.
//! - **Payout.** The approved amount, as far as the pool allows; the rest is paid as the pool refills (`settle`).

use near_sdk::json_types::{U128, U64};
use near_sdk::serde_json::{self, json, Value};
use near_sdk::store::{LookupMap, Vector};
use near_sdk::{env, near, require, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseResult};

pub const VERSION: &str = "1.0.0";
const STANDARD: &str = "hermit-insurance";
pub const PERIOD_NS: u64 = 30 * 24 * 60 * 60 * 1_000_000_000;
/// Paid with each claim: covers its storage (evidence up to 4 KB) and keeps spam out.
pub const CLAIM_DEPOSIT: u128 = 50_000_000_000_000_000_000_000; // 0.05 NEAR
const FT_TRANSFER_GAS: Gas = Gas::from_tgas(15);
const CALLBACK_GAS: Gas = Gas::from_tgas(15);

#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq)]
pub struct Claim {
    pub id: u64,
    pub by: AccountId,
    /// Black Box fingerprint of the move (64 hex).
    pub fp: String,
    /// The text behind the fingerprint, as the device kept it; sha256(evidence) == fp.
    pub evidence: String,
    /// What the claimant says they lost, in USDC units (6 decimals).
    pub loss: U128,
    pub note: String,
    pub filed_ns: U64,
    /// open, approved, rejected, paid
    pub status: String,
    pub ai_verdict: Option<String>,
    pub ai_reason: Option<String>,
    pub award: U128,
    pub paid: U128,
    pub pending: U128,
    pub reason: Option<String>,
    pub decided_ns: Option<U64>,
}

#[near(serializers = [json])]
pub struct Info {
    pub version: String,
    pub owner: AccountId,
    pub reviewer: AccountId,
    pub token: AccountId,
    pub price: U128,
    pub period_days: u32,
    pub pool: U128,
    pub paid_in: U128,
    pub paid_out: U128,
    pub owed: U128,
    pub claims: u64,
    pub members: u64,
}

#[near(serializers = [json])]
pub struct Cover {
    pub active: bool,
    pub expires_ns: U64,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Insurance {
    owner: AccountId,
    reviewer: AccountId,
    token: AccountId,
    price: u128,
    pool: u128,
    paid_in: u128,
    paid_out: u128,
    owed: u128,
    covers: LookupMap<AccountId, u64>,
    claims: Vector<Claim>,
    by_fp: LookupMap<String, u64>,
    members: u64,
}

fn emit(event: &str, data: Value) {
    let e = json!({ "standard": STANDARD, "version": VERSION, "event": event, "data": [data] });
    env::log_str(&format!("EVENT_JSON:{}", e));
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn text(s: &str, max: usize, what: &str) {
    require!(s.len() <= max, format!("{what} must be at most {max} bytes"));
    require!(!s.chars().any(|c| c.is_control() && c != '\n'), format!("{what} has a control character"));
}

#[near]
impl Insurance {
    #[init]
    pub fn new(owner: AccountId, reviewer: AccountId, token: AccountId, price: U128) -> Self {
        require!(price.0 > 0, "price must be more than 0");
        Self {
            owner,
            reviewer,
            token,
            price: price.0,
            pool: 0,
            paid_in: 0,
            paid_out: 0,
            owed: 0,
            covers: LookupMap::new(b"c".to_vec()),
            claims: Vector::new(b"l".to_vec()),
            by_fp: LookupMap::new(b"f".to_vec()),
            members: 0,
        }
    }

    fn only_owner(&self) {
        near_sdk::assert_one_yocto();
        require!(env::predecessor_account_id() == self.owner, "Only the owner can do this");
    }

    // ---------------------------------------------------------------- money in

    /// NEP-141 receiver. `msg` is "cover" (buy 30 days per `price`) or "fund" (add to the pool). Returns what it didn't use.
    pub fn ft_on_transfer(&mut self, sender_id: AccountId, amount: U128, msg: String) -> U128 {
        if env::predecessor_account_id() != self.token {
            return amount;
        }
        match msg.as_str() {
            "cover" => {
                let periods = amount.0 / self.price;
                if periods == 0 || periods > 120 {
                    return amount;
                }
                let used = periods * self.price;
                let now = env::block_timestamp();
                let prev = self.covers.get(&sender_id).copied();
                if prev.is_none() {
                    self.members += 1;
                }
                let start = prev.filter(|e| *e > now).unwrap_or(now);
                let expires = start + PERIOD_NS * periods as u64;
                self.covers.insert(sender_id.clone(), expires);
                self.pool += used;
                self.paid_in += used;
                emit("cover", json!({ "account": sender_id, "paid": U128(used), "expires_ns": U64(expires) }));
                U128(amount.0 - used)
            }
            "fund" => {
                self.pool += amount.0;
                self.paid_in += amount.0;
                emit("fund", json!({ "from": sender_id, "amount": amount }));
                U128(0)
            }
            _ => amount,
        }
    }

    // ---------------------------------------------------------------- claims

    /// File a claim for one Black Box record. Needs active cover and a 0.05 NEAR deposit (storage).
    #[payable]
    pub fn file_claim(&mut self, fp: String, evidence: String, loss: U128, note: String) -> u64 {
        require!(env::attached_deposit() >= NearToken::from_yoctonear(CLAIM_DEPOSIT), "Attach 0.05 NEAR to file a claim");
        let by = env::predecessor_account_id();
        let now = env::block_timestamp();
        require!(self.covers.get(&by).map(|e| *e > now).unwrap_or(false), "No active cover for this account");
        require!(is_hex(&fp, 64), "fp must be a SHA-256 as 64 lowercase hex characters");
        require!(!evidence.is_empty(), "evidence is required");
        text(&evidence, 4096, "evidence");
        text(&note, 600, "note");
        require!(hex(&env::sha256(evidence.as_bytes())) == fp, "evidence doesn't match the fingerprint");
        require!(loss.0 > 0, "loss must be more than 0");
        require!(!self.by_fp.contains_key(&fp), "This record already has a claim");
        let id = self.claims.len() as u64;
        self.by_fp.insert(fp.clone(), id);
        self.claims.push(Claim {
            id,
            by: by.clone(),
            fp: fp.clone(),
            evidence,
            loss,
            note,
            filed_ns: U64(now),
            status: "open".into(),
            ai_verdict: None,
            ai_reason: None,
            award: U128(0),
            paid: U128(0),
            pending: U128(0),
            reason: None,
            decided_ns: None,
        });
        emit("claim_filed", json!({ "id": U64(id), "by": by, "fp": fp, "loss": loss }));
        id
    }

    /// The AI reviewer's verdict and reason, on chain before the owner decides. Can't move money.
    pub fn ai_review(&mut self, id: u64, verdict: String, reason: String) {
        require!(env::predecessor_account_id() == self.reviewer, "Only the reviewer can do this");
        require!(["approve", "reject", "unsure"].contains(&verdict.as_str()), "verdict is approve, reject or unsure");
        text(&reason, 600, "reason");
        let mut c = self.claim_mut(id);
        require!(c.status == "open", "This claim is already decided");
        c.ai_verdict = Some(verdict.clone());
        c.ai_reason = Some(reason.clone());
        self.claims.replace(id as u32, c);
        emit("ai_review", json!({ "id": U64(id), "verdict": verdict, "reason": reason }));
    }

    /// The owner's decision. Approving pays as much of `award` as the pool holds now; the rest waits for `settle`.
    #[payable]
    pub fn decide(&mut self, id: u64, approve: bool, award: U128, reason: String) -> Option<Promise> {
        self.only_owner();
        text(&reason, 600, "reason");
        require!(!reason.is_empty(), "Give a reason");
        let mut c = self.claim_mut(id);
        require!(c.status == "open", "This claim is already decided");
        c.decided_ns = Some(U64(env::block_timestamp()));
        c.reason = Some(reason.clone());
        if !approve {
            c.status = "rejected".into();
            self.claims.replace(id as u32, c);
            emit("claim_rejected", json!({ "id": U64(id), "reason": reason }));
            return None;
        }
        require!(award.0 > 0, "award must be more than 0");
        c.status = "approved".into();
        c.award = award;
        self.owed += award.0;
        self.claims.replace(id as u32, c);
        emit("claim_approved", json!({ "id": U64(id), "award": award, "reason": reason }));
        self.pay(id)
    }

    /// Pays what an approved claim is still owed, as far as the pool allows. Anyone can call it once the pool refills.
    pub fn settle(&mut self, id: u64) -> Option<Promise> {
        self.pay(id)
    }

    fn pay(&mut self, id: u64) -> Option<Promise> {
        let mut c = self.claim_mut(id);
        require!(c.status == "approved", "Only an approved claim is paid");
        let left = c.award.0 - c.paid.0 - c.pending.0;
        let amount = left.min(self.pool);
        if amount == 0 {
            return None;
        }
        self.pool -= amount;
        c.pending = U128(c.pending.0 + amount);
        let to = c.by.clone();
        self.claims.replace(id as u32, c);
        let args = serde_json::to_vec(&json!({ "receiver_id": to, "amount": U128(amount), "memo": format!("Hermit AI insurance claim {id}") }))
            .unwrap_or_else(|_| env::panic_str("args"));
        Some(
            Promise::new(self.token.clone())
                .function_call("ft_transfer".into(), args, NearToken::from_yoctonear(1), FT_TRANSFER_GAS)
                .then(
                    Promise::new(env::current_account_id()).function_call(
                        "on_paid".into(),
                        serde_json::to_vec(&json!({ "id": id, "amount": U128(amount) })).unwrap(),
                        NearToken::from_yoctonear(0),
                        CALLBACK_GAS,
                    ),
                ),
        )
    }

    #[private]
    pub fn on_paid(&mut self, id: u64, amount: U128) {
        let ok = env::promise_results_count() == 1 && matches!(env::promise_result(0), PromiseResult::Successful(_));
        let mut c = self.claim_mut(id);
        c.pending = U128(c.pending.0 - amount.0);
        if ok {
            c.paid = U128(c.paid.0 + amount.0);
            self.paid_out += amount.0;
            self.owed -= amount.0;
            if c.paid == c.award {
                c.status = "paid".into();
            }
            emit("claim_paid", json!({ "id": U64(id), "amount": amount, "to": c.by }));
        } else {
            self.pool += amount.0;
            emit("payout_failed", json!({ "id": U64(id), "amount": amount }));
        }
        self.claims.replace(id as u32, c);
    }

    fn claim_mut(&self, id: u64) -> Claim {
        self.claims.get(id as u32).cloned().unwrap_or_else(|| env::panic_str("No claim with this id"))
    }

    // ---------------------------------------------------------------- admin (never touches the pool)

    #[payable]
    pub fn set_owner(&mut self, owner: AccountId) {
        self.only_owner();
        emit("owner_changed", json!({ "from": self.owner, "to": owner }));
        self.owner = owner;
    }

    #[payable]
    pub fn set_reviewer(&mut self, reviewer: AccountId) {
        self.only_owner();
        emit("reviewer_changed", json!({ "from": self.reviewer, "to": reviewer }));
        self.reviewer = reviewer;
    }

    #[payable]
    pub fn set_price(&mut self, price: U128) {
        self.only_owner();
        require!(price.0 > 0, "price must be more than 0");
        emit("price_changed", json!({ "from": U128(self.price), "to": price }));
        self.price = price.0;
    }

    // ---------------------------------------------------------------- views

    pub fn info(&self) -> Info {
        Info {
            version: VERSION.into(),
            owner: self.owner.clone(),
            reviewer: self.reviewer.clone(),
            token: self.token.clone(),
            price: U128(self.price),
            period_days: (PERIOD_NS / 86_400_000_000_000) as u32,
            pool: U128(self.pool),
            paid_in: U128(self.paid_in),
            paid_out: U128(self.paid_out),
            owed: U128(self.owed),
            claims: self.claims.len() as u64,
            members: self.members,
        }
    }

    pub fn cover_of(&self, account_id: AccountId) -> Cover {
        let e = self.covers.get(&account_id).copied().unwrap_or(0);
        Cover { active: e > env::block_timestamp(), expires_ns: U64(e) }
    }

    pub fn get_claim(&self, id: u64) -> Option<Claim> {
        self.claims.get(id as u32).cloned()
    }

    /// Newest first.
    pub fn claims(&self, from_index: Option<u64>, limit: Option<u64>) -> Vec<Claim> {
        let n = self.claims.len() as u64;
        let from = from_index.unwrap_or(0);
        let limit = limit.unwrap_or(20).min(50);
        (from..n.min(from.saturating_add(limit)))
            .filter_map(|i| self.claims.get((n - 1 - i) as u32).cloned())
            .collect()
    }
}

#[cfg(test)]
mod tests;
