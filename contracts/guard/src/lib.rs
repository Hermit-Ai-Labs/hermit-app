//! Hermit Guard: one shared contract, one vault per NEAR account, small "pockets" with spending rules.
//!
//! READ THIS FIRST (auditors):
//! * No admin, no upgrade method, no owner of the contract. Funds move only through the paths listed in README.md.
//! * Every owner-only method is `#[payable]` and calls `assert_one_yocto()`. A function-call access key cannot attach a
//!   deposit, so a pocket key can never reach them, on top of the key's own method list (`spend`, `request`).
//! * Every payout follows checks -> effects -> interaction: the balance and the pocket's window are reduced BEFORE the
//!   cross-contract call; `on_payout` (private) puts them back if the transfer failed.
//! * All state per vault is bounded by the constants below. `open_vault` prepays storage for the maximum size.
//! * Amounts are in token units. There is no price oracle, so a "daily cap" of a pocket is a cap in ITS token.

use near_sdk::json_types::{U128, U64};
use near_sdk::serde_json::{self, json, Value};
use near_sdk::store::{LookupMap, Vector};
use near_sdk::{
    assert_one_yocto, env, near, require, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseResult, PublicKey,
};

pub const VERSION: &str = "1.0.0";
/// Token id of native NEAR. Every other token is the account id of an NEP-141 contract.
pub const NEAR: &str = "near";

// ---- bounds (every collection in a vault is capped by one of these) ----
pub const MAX_POCKETS: usize = 8;
pub const MAX_ORDERS: usize = 20;
pub const MAX_REQUESTS: usize = 10;
pub const MAX_RECEIPTS: usize = 50;
pub const MAX_RECIPIENTS: usize = 20;
pub const MAX_NAME_BYTES: usize = 24;
pub const MAX_TEXT_BYTES: usize = 140;
pub const MAX_TOKENS: usize = 8;
pub const MIN_INTERVAL_SECONDS: u64 = 3600;
/// 10 years. Keeps interval * 1e9 far inside u64.
pub const MAX_INTERVAL_SECONDS: u64 = 315_360_000;
pub const DAY_NS: u64 = 86_400_000_000_000;
pub const REQUEST_TTL_NS: u64 = 7 * DAY_NS;
/// View calls that walk owners never read more than this many vaults.
pub const MAX_PAGE: u32 = 20;

/// Storage deposit paid by `open_vault`: 0.5 NEAR = 50_000 bytes at 1e19 yocto per byte.
/// A vault filled to every limit serializes to about 41_100 bytes (unit test `worst_case_vault_fits_the_deposit`
/// measures it), plus two storage records of under 300 bytes of overhead in total. Margin: about 8 KB.
pub const STORAGE_DEPOSIT: u128 = 500_000_000_000_000_000_000_000;
/// Same deposit expressed in bytes; the unit test checks `worst case + overhead <= this`.
pub const STORAGE_DEPOSIT_BYTES: u64 = 50_000;

const FT_TRANSFER_GAS: Gas = Gas::from_tgas(30);
const CALLBACK_GAS: Gas = Gas::from_tgas(40);
/// A payout call must arrive with at least this much gas left, so the callback can never be starved.
const MIN_GAS_FOR_PAYOUT: u64 = 120_000_000_000_000;

// ---------------------------------------------------------------- data

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct TokenBalance {
    pub token: String,
    pub amount: U128,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Spend,
    Order,
    Approved,
    Withdraw,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct Pocket {
    pub name: String,
    pub public_key: Option<PublicKey>,
    pub token: String,
    pub per_payment_cap: U128,
    pub daily_cap: U128,
    /// Spent inside the current fixed window. Only meaningful while `now < window_start + 24h`.
    pub spent: U128,
    /// Start of the current fixed 24h window (set by the first spend after the previous window ended). 0 = none yet.
    pub window_start: U64,
    /// Empty list = any recipient.
    pub allowed_recipients: Vec<AccountId>,
    pub expires_at: Option<U64>,
    pub paused: bool,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct Order {
    pub id: u64,
    pub pocket: String,
    pub token: String,
    pub amount: U128,
    pub recipient: AccountId,
    pub interval_seconds: u64,
    pub next_due_ns: U64,
    pub remaining: Option<u32>,
    pub memo: String,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct Request {
    pub id: u64,
    pub pocket: String,
    pub token: String,
    pub amount: U128,
    pub recipient: AccountId,
    pub reason: String,
    pub created_ns: U64,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct Receipt {
    pub id: u64,
    pub time: U64,
    pub pocket: String,
    pub token: String,
    pub amount: U128,
    pub recipient: AccountId,
    pub reason: String,
    pub kind: Kind,
    /// true until the transfer is known to have failed. It is set optimistically when the payout is sent and
    /// flipped to false by `on_payout` if the transfer failed (the money is then back in the vault).
    pub ok: bool,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct Vault {
    pub frozen: bool,
    pub balances: Vec<TokenBalance>,
    pub pockets: Vec<Pocket>,
    pub orders: Vec<Order>,
    pub requests: Vec<Request>,
    /// Ring buffer of the last MAX_RECEIPTS receipts. Receipt number n lives at index n % MAX_RECEIPTS.
    pub receipts: Vec<Receipt>,
    pub receipts_total: u64,
    pub next_id: u64,
    /// Payouts sent but not yet settled by `on_payout`. close_vault is refused while this is not 0.
    pub pending_out: u32,
    pub storage_paid: U128,
    /// Position of the owner in `Guard::owners`.
    pub owner_index: u32,
}

/// What `create_pocket` / `update_pocket` take.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct PocketConfig {
    pub name: String,
    pub public_key: Option<PublicKey>,
    pub token: String,
    pub per_payment_cap: U128,
    pub daily_cap: U128,
    #[serde(default)]
    pub allowed_recipients: Vec<AccountId>,
    pub expires_at: Option<U64>,
}

#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct VaultView {
    pub owner: AccountId,
    pub frozen: bool,
    pub balances: Vec<TokenBalance>,
    pub pockets: u32,
    pub orders: u32,
    pub requests: u32,
    pub receipts_total: u64,
    pub pending_out: u32,
    pub storage_paid: U128,
}

#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct DueOrder {
    pub owner: AccountId,
    pub order_id: u64,
    pub pocket: String,
    pub token: String,
    pub amount: U128,
    pub recipient: AccountId,
    pub next_due_ns: U64,
}

/// Everything `on_payout` needs to undo a failed payout.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct Settle {
    pub owner: AccountId,
    pub token: String,
    pub amount: U128,
    pub receipt_id: u64,
    /// Pocket whose window was charged (None for approvals and withdrawals).
    pub pocket: Option<String>,
    pub window_start: U64,
    /// The order exactly as it was before this run (None unless kind = order).
    pub order_before: Option<Order>,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Guard {
    vaults: LookupMap<AccountId, Vault>,
    /// Enumerable list of vault owners (for `due_orders`). Vault.owner_index points back into it.
    owners: Vector<AccountId>,
    /// Allowlist, set once at init, never changed.
    tokens: Vec<String>,
}

// ---------------------------------------------------------------- pure rules (no storage, easy to test)

impl Vault {
    fn new(owner_index: u32, paid: u128) -> Self {
        Vault {
            frozen: false,
            balances: vec![],
            pockets: vec![],
            orders: vec![],
            requests: vec![],
            receipts: vec![],
            receipts_total: 0,
            next_id: 1,
            pending_out: 0,
            storage_paid: U128(paid),
            owner_index,
        }
    }

    pub fn balance(&self, token: &str) -> u128 {
        self.balances.iter().find(|b| b.token == token).map_or(0, |b| b.amount.0)
    }

    fn credit(&mut self, token: &str, amount: u128) {
        match self.balances.iter().position(|b| b.token == token) {
            Some(i) => {
                let cur = self.balances[i].amount.0;
                self.balances[i].amount =
                    U128(cur.checked_add(amount).unwrap_or_else(|| env::panic_str("balance overflow")));
            }
            None => self.balances.push(TokenBalance { token: token.to_string(), amount: U128(amount) }),
        }
    }

    fn debit(&mut self, token: &str, amount: u128) {
        let i = self
            .balances
            .iter()
            .position(|b| b.token == token)
            .unwrap_or_else(|| env::panic_str("insufficient vault balance"));
        let cur = self.balances[i].amount.0;
        require!(cur >= amount, "insufficient vault balance");
        self.balances[i].amount = U128(cur - amount);
    }

    fn take_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = id.checked_add(1).unwrap_or_else(|| env::panic_str("id overflow"));
        id
    }

    fn push_receipt(&mut self, mut r: Receipt) -> u64 {
        let id = self.receipts_total;
        r.id = id;
        let slot = (id % MAX_RECEIPTS as u64) as usize;
        if self.receipts.len() < MAX_RECEIPTS {
            self.receipts.push(r);
        } else {
            self.receipts[slot] = r;
        }
        self.receipts_total = id + 1;
        id
    }

    fn mark_receipt_failed(&mut self, id: u64) {
        let slot = (id % MAX_RECEIPTS as u64) as usize;
        if let Some(r) = self.receipts.get_mut(slot) {
            if r.id == id {
                r.ok = false;
            }
        }
    }

    /// Receipts oldest first.
    fn receipts_in_order(&self) -> Vec<Receipt> {
        if self.receipts_total <= MAX_RECEIPTS as u64 {
            return self.receipts.clone();
        }
        let start = (self.receipts_total % MAX_RECEIPTS as u64) as usize;
        let mut out = self.receipts[start..].to_vec();
        out.extend_from_slice(&self.receipts[..start]);
        out
    }

    fn drop_expired_requests(&mut self, now: u64) {
        self.requests.retain(|r| now < r.created_ns.0.saturating_add(REQUEST_TTL_NS));
    }
}

fn pocket_live(p: &Pocket, now: u64) -> Result<(), &'static str> {
    if p.paused {
        return Err("pocket paused");
    }
    if p.expires_at.map_or(false, |e| now >= e.0) {
        return Err("pocket expired");
    }
    Ok(())
}

/// Spent so far in the window that is open at `now` (0 if the last window has ended).
fn window_used(p: &Pocket, now: u64) -> u128 {
    if p.window_start.0 == 0 || now >= p.window_start.0.saturating_add(DAY_NS) {
        0
    } else {
        p.spent.0
    }
}

/// The one rule set for spend and for standing orders.
fn check_payment(p: &Pocket, token: &str, amount: u128, to: &AccountId, now: u64) -> Result<(), &'static str> {
    pocket_live(p, now)?;
    if amount == 0 {
        return Err("amount is zero");
    }
    if p.token != token {
        return Err("wrong token for this pocket");
    }
    if !p.allowed_recipients.is_empty() && !p.allowed_recipients.contains(to) {
        return Err("recipient not allowed");
    }
    if amount > p.per_payment_cap.0 {
        return Err("over per-payment cap");
    }
    match window_used(p, now).checked_add(amount) {
        Some(total) if total <= p.daily_cap.0 => Ok(()),
        _ => Err("over daily cap"),
    }
}

/// Counts `amount` against the pocket's window (opening a new window if needed). Returns the window start.
fn charge_window(p: &mut Pocket, now: u64, amount: u128) -> u64 {
    if p.window_start.0 == 0 || now >= p.window_start.0.saturating_add(DAY_NS) {
        p.window_start = U64(now);
        p.spent = U128(0);
    }
    p.spent = U128(p.spent.0.checked_add(amount).unwrap_or_else(|| env::panic_str("overflow")));
    p.window_start.0
}

/// Why this order cannot be paid right now (None index = it can). Used by execute_order and by due_orders.
fn check_order(v: &Vault, o: &Order, now: u64) -> Result<usize, &'static str> {
    if v.frozen {
        return Err("vault frozen");
    }
    if now < o.next_due_ns.0 {
        return Err("order not due yet");
    }
    let pi = v.pockets.iter().position(|p| p.name == o.pocket).ok_or("pocket missing")?;
    check_payment(&v.pockets[pi], &o.token, o.amount.0, &o.recipient, now)?;
    if v.balance(&o.token) < o.amount.0 {
        return Err("insufficient vault balance");
    }
    Ok(pi)
}

fn check_text(s: &str, what: &str) {
    require!(s.len() <= MAX_TEXT_BYTES, format!("{} is longer than 140 bytes", what));
}

fn validate_config(c: &PocketConfig, tokens: &[String], now: u64) {
    require!(!c.name.is_empty() && c.name.len() <= MAX_NAME_BYTES, "pocket name must be 1 to 24 bytes");
    require!(tokens.iter().any(|t| *t == c.token), "token not allowed");
    require!(c.per_payment_cap.0 > 0, "per_payment_cap must be above 0");
    require!(c.daily_cap.0 >= c.per_payment_cap.0, "daily_cap must be at least per_payment_cap");
    require!(c.allowed_recipients.len() <= MAX_RECIPIENTS, "too many allowed recipients (max 20)");
    if let Some(e) = c.expires_at {
        require!(e.0 > now, "expires_at must be in the future");
    }
}

fn emit(event: &str, data: Value) {
    let e = json!({ "standard": "hermit-guard", "version": "1.0.0", "event": event, "data": [data] });
    env::log_str(&format!("EVENT_JSON:{}", e));
}

fn require_gas() {
    let left = env::prepaid_gas().as_gas().saturating_sub(env::used_gas().as_gas());
    require!(left >= MIN_GAS_FOR_PAYOUT, "attach at least 125 TGas (150 recommended)");
}

fn require_not_self(to: &AccountId) {
    require!(*to != env::current_account_id(), "recipient cannot be the guard contract");
}

/// Effects half of a payout, then the interaction. The caller has already checked every rule.
/// Reduces the vault balance, records the receipt, and returns the transfer promise with `on_payout` chained.
#[allow(clippy::too_many_arguments)]
fn start_payout(
    v: &mut Vault,
    owner: &AccountId,
    kind: Kind,
    pocket: Option<String>,
    token: &str,
    to: &AccountId,
    amount: u128,
    reason: String,
    window_start: u64,
    order_before: Option<Order>,
    now: u64,
) -> Promise {
    v.debit(token, amount);
    v.pending_out = v.pending_out.checked_add(1).unwrap_or_else(|| env::panic_str("too many payouts in flight"));
    let receipt_id = v.push_receipt(Receipt {
        id: 0,
        time: U64(now),
        pocket: pocket.clone().unwrap_or_default(),
        token: token.to_string(),
        amount: U128(amount),
        recipient: to.clone(),
        reason,
        kind,
        ok: true,
    });
    let transfer = if token == NEAR {
        Promise::new(to.clone()).transfer(NearToken::from_yoctonear(amount))
    } else {
        let token_id: AccountId = token.parse().unwrap_or_else(|_| env::panic_str("bad token id"));
        let args = json!({ "receiver_id": to, "amount": U128(amount) });
        Promise::new(token_id).function_call(
            "ft_transfer".to_string(),
            serde_json::to_vec(&args).unwrap_or_else(|_| env::panic_str("args")),
            NearToken::from_yoctonear(1),
            FT_TRANSFER_GAS,
        )
    };
    let settle = Settle {
        owner: owner.clone(),
        token: token.to_string(),
        amount: U128(amount),
        receipt_id,
        pocket,
        window_start: U64(window_start),
        order_before,
    };
    transfer.then(Guard::ext(env::current_account_id()).with_static_gas(CALLBACK_GAS).on_payout(settle))
}

// ---------------------------------------------------------------- storage helpers (not exported)

impl Guard {
    fn load(&self, owner: &AccountId) -> Vault {
        self.vaults.get(owner).unwrap_or_else(|| env::panic_str("no vault for this account")).clone()
    }

    fn save(&mut self, owner: &AccountId, v: Vault) {
        self.vaults.insert(owner.clone(), v);
    }

    /// Owner-only entry: exactly 1 yocto (so no function-call key can get here), vault of the caller.
    fn owner_entry(&self) -> (AccountId, Vault) {
        assert_one_yocto();
        let owner = env::predecessor_account_id();
        let v = self.load(&owner);
        (owner, v)
    }

    /// Pocket-key entry: direct call, signer key must be a pocket of the caller's vault.
    fn pocket_entry(&self) -> (AccountId, Vault, usize) {
        let owner = env::predecessor_account_id();
        require!(env::signer_account_id() == owner, "direct calls only");
        let pk = env::signer_account_pk();
        let v = self.load(&owner);
        let pi = v
            .pockets
            .iter()
            .position(|p| p.public_key.as_ref() == Some(&pk))
            .unwrap_or_else(|| env::panic_str("this key is not a pocket key of the vault"));
        (owner, v, pi)
    }
}

// ---------------------------------------------------------------- public API

#[near]
impl Guard {
    /// `tokens` is the immutable allowlist: must contain "near", at most 8 entries, others are NEP-141 account ids.
    #[init]
    #[private]
    pub fn new(tokens: Vec<String>) -> Self {
        require!(tokens.iter().any(|t| t == NEAR), "allowlist must contain near");
        require!(tokens.len() <= MAX_TOKENS, "too many tokens");
        for (i, t) in tokens.iter().enumerate() {
            if t != NEAR {
                require!(t.parse::<AccountId>().is_ok(), "bad token account id");
            }
            require!(!tokens[..i].contains(t), "duplicate token");
        }
        Self { vaults: LookupMap::new(b"v".to_vec()), owners: Vector::new(b"o".to_vec()), tokens }
    }

    // ------------------------------------------------ vault lifecycle (owner)

    /// Attach at least STORAGE_DEPOSIT; anything above it is credited to the vault's NEAR balance.
    #[payable]
    pub fn open_vault(&mut self) {
        let owner = env::predecessor_account_id();
        require!(!self.vaults.contains_key(&owner), "vault already exists");
        let dep = env::attached_deposit().as_yoctonear();
        require!(dep >= STORAGE_DEPOSIT, "attach at least the storage deposit (see storage_cost)");
        let idx = self.owners.len();
        self.owners.push(owner.clone());
        let mut v = Vault::new(idx, STORAGE_DEPOSIT);
        let extra = dep - STORAGE_DEPOSIT;
        if extra > 0 {
            v.credit(NEAR, extra);
        }
        self.save(&owner, v);
        emit("vault_opened", json!({ "owner": owner, "storage_deposit": U128(STORAGE_DEPOSIT), "initial_near": U128(extra) }));
    }

    /// Credit attached NEAR to the caller's vault. A function-call key cannot attach a deposit, so owner only.
    #[payable]
    pub fn deposit_near(&mut self) {
        let owner = env::predecessor_account_id();
        let amount = env::attached_deposit().as_yoctonear();
        require!(amount > 0, "attach NEAR");
        let mut v = self.load(&owner);
        v.credit(NEAR, amount);
        self.save(&owner, v);
        emit("deposit", json!({ "owner": owner, "token": NEAR, "amount": U128(amount) }));
    }

    /// NEP-141 receiver. Called by the token contract; `sender_id` is whoever sent the tokens.
    /// Credits the sender's vault only for allowlisted tokens and only if the sender has a vault. Returns the unused part.
    pub fn ft_on_transfer(&mut self, sender_id: AccountId, amount: U128, msg: String) -> U128 {
        let _ = msg;
        let token = env::predecessor_account_id().to_string();
        if token == NEAR || !self.tokens.iter().any(|t| *t == token) {
            return amount;
        }
        let mut v = match self.vaults.get(&sender_id) {
            Some(v) => v.clone(),
            None => return amount,
        };
        if v.balance(&token).checked_add(amount.0).is_none() {
            return amount;
        }
        v.credit(&token, amount.0);
        self.save(&sender_id, v);
        emit("deposit", json!({ "owner": sender_id, "token": token, "amount": amount }));
        U128(0)
    }

    #[payable]
    pub fn close_vault(&mut self) -> Promise {
        let (owner, v) = self.owner_entry();
        require!(v.balances.iter().all(|b| b.amount.0 == 0), "withdraw every balance first");
        require!(v.pending_out == 0, "payouts still in flight, try again in a moment");
        require!(self.owners.get(v.owner_index) == Some(&owner), "owner index corrupted");
        self.vaults.remove(&owner);
        self.owners.swap_remove(v.owner_index);
        if v.owner_index < self.owners.len() {
            let moved = self.owners.get(v.owner_index).unwrap_or_else(|| env::panic_str("index")).clone();
            let mut mv = self.load(&moved);
            mv.owner_index = v.owner_index;
            self.save(&moved, mv);
        }
        emit("vault_closed", json!({ "owner": owner, "refund": v.storage_paid }));
        Promise::new(owner).transfer(NearToken::from_yoctonear(v.storage_paid.0))
    }

    // ------------------------------------------------ pockets (owner)

    #[payable]
    pub fn create_pocket(&mut self, config: PocketConfig) {
        let (owner, mut v) = self.owner_entry();
        let now = env::block_timestamp();
        validate_config(&config, &self.tokens, now);
        require!(v.pockets.len() < MAX_POCKETS, "pocket limit reached (8)");
        require!(!v.pockets.iter().any(|p| p.name == config.name), "pocket name already used");
        if let Some(k) = &config.public_key {
            require!(!v.pockets.iter().any(|p| p.public_key.as_ref() == Some(k)), "key already used by another pocket");
        }
        v.pockets.push(Pocket {
            name: config.name,
            public_key: config.public_key,
            token: config.token,
            per_payment_cap: config.per_payment_cap,
            daily_cap: config.daily_cap,
            spent: U128(0),
            window_start: U64(0),
            allowed_recipients: config.allowed_recipients,
            expires_at: config.expires_at,
            paused: false,
        });
        self.save(&owner, v);
    }

    /// Replaces the settings of the pocket called `config.name`. Spent amount and pause state are kept
    /// (the window restarts if the token changes).
    #[payable]
    pub fn update_pocket(&mut self, config: PocketConfig) {
        let (owner, mut v) = self.owner_entry();
        let now = env::block_timestamp();
        validate_config(&config, &self.tokens, now);
        let i = v
            .pockets
            .iter()
            .position(|p| p.name == config.name)
            .unwrap_or_else(|| env::panic_str("no such pocket"));
        if let Some(k) = &config.public_key {
            require!(
                !v.pockets.iter().enumerate().any(|(j, p)| j != i && p.public_key.as_ref() == Some(k)),
                "key already used by another pocket"
            );
        }
        let p = &mut v.pockets[i];
        if p.token != config.token {
            p.spent = U128(0);
            p.window_start = U64(0);
        }
        p.public_key = config.public_key;
        p.token = config.token;
        p.per_payment_cap = config.per_payment_cap;
        p.daily_cap = config.daily_cap;
        p.allowed_recipients = config.allowed_recipients;
        p.expires_at = config.expires_at;
        self.save(&owner, v);
    }

    /// Removes the pocket and, with it, its standing orders and pending requests.
    #[payable]
    pub fn remove_pocket(&mut self, name: String) {
        let (owner, mut v) = self.owner_entry();
        let i = v.pockets.iter().position(|p| p.name == name).unwrap_or_else(|| env::panic_str("no such pocket"));
        v.pockets.remove(i);
        v.orders.retain(|o| o.pocket != name);
        v.requests.retain(|r| r.pocket != name);
        self.save(&owner, v);
    }

    #[payable]
    pub fn pause_pocket(&mut self, name: String) {
        self.set_paused(name, true);
    }

    #[payable]
    pub fn resume_pocket(&mut self, name: String) {
        self.set_paused(name, false);
    }

    // ------------------------------------------------ standing orders (owner creates, anyone triggers)

    /// `first_due_ns` defaults to now + interval; a time in the past means "due immediately".
    #[payable]
    #[allow(clippy::too_many_arguments)]
    pub fn create_order(
        &mut self,
        pocket: String,
        amount: U128,
        recipient: AccountId,
        interval_seconds: u64,
        first_due_ns: Option<U64>,
        remaining: Option<u32>,
        memo: String,
    ) -> u64 {
        let (owner, mut v) = self.owner_entry();
        let now = env::block_timestamp();
        require!(v.orders.len() < MAX_ORDERS, "order limit reached (20)");
        require!(
            (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(&interval_seconds),
            "interval must be between 3600 seconds and 10 years"
        );
        require!(remaining != Some(0), "remaining must be above 0");
        check_text(&memo, "memo");
        require_not_self(&recipient);
        let p = v.pockets.iter().find(|p| p.name == pocket).unwrap_or_else(|| env::panic_str("no such pocket"));
        require!(amount.0 > 0 && amount.0 <= p.per_payment_cap.0, "amount must be above 0 and within the pocket's per-payment cap");
        require!(p.allowed_recipients.is_empty() || p.allowed_recipients.contains(&recipient), "recipient not allowed by the pocket");
        let token = p.token.clone();
        let next_due = first_due_ns.map_or(now.saturating_add(interval_seconds * 1_000_000_000), |t| t.0);
        let id = v.take_id();
        v.orders.push(Order {
            id,
            pocket,
            token,
            amount,
            recipient,
            interval_seconds,
            next_due_ns: U64(next_due),
            remaining,
            memo,
        });
        self.save(&owner, v);
        id
    }

    #[payable]
    pub fn cancel_order(&mut self, order_id: u64) {
        let (owner, mut v) = self.owner_entry();
        let i = v.orders.iter().position(|o| o.id == order_id).unwrap_or_else(|| env::panic_str("no such order"));
        v.orders.remove(i);
        self.save(&owner, v);
    }

    /// Anyone may call. Pays only if the order is due and every pocket rule passes; otherwise panics without changing state.
    pub fn execute_order(&mut self, owner: AccountId, order_id: u64) -> Promise {
        require_gas();
        let mut v = self.load(&owner);
        let now = env::block_timestamp();
        let oi = v.orders.iter().position(|o| o.id == order_id).unwrap_or_else(|| env::panic_str("no such order"));
        let before = v.orders[oi].clone();
        let pi = check_order(&v, &before, now).unwrap_or_else(|e| env::panic_str(e));
        require_not_self(&before.recipient);
        // Advance by whole intervals to the first due time strictly after now: no catch-up bursts.
        let interval_ns = before.interval_seconds * 1_000_000_000;
        let periods = (now - before.next_due_ns.0) / interval_ns + 1;
        let next = u64::try_from(before.next_due_ns.0 as u128 + periods as u128 * interval_ns as u128)
            .unwrap_or_else(|_| env::panic_str("schedule overflow"));
        match before.remaining {
            Some(n) if n <= 1 => {
                v.orders.remove(oi);
            }
            Some(n) => {
                v.orders[oi].remaining = Some(n - 1);
                v.orders[oi].next_due_ns = U64(next);
            }
            None => {
                v.orders[oi].next_due_ns = U64(next);
            }
        }
        let ws = charge_window(&mut v.pockets[pi], now, before.amount.0);
        let promise = start_payout(
            &mut v,
            &owner,
            Kind::Order,
            Some(before.pocket.clone()),
            &before.token,
            &before.recipient,
            before.amount.0,
            before.memo.clone(),
            ws,
            Some(before.clone()),
            now,
        );
        self.save(&owner, v);
        emit(
            "order_paid",
            json!({ "owner": owner, "order_id": order_id, "pocket": before.pocket, "token": before.token,
                    "amount": before.amount, "recipient": before.recipient }),
        );
        promise
    }

    // ------------------------------------------------ pocket key: spend / request

    /// Called with a pocket's function-call key. Pays if every rule of the pocket holds.
    pub fn spend(&mut self, token: String, amount: U128, recipient: AccountId, reason: String) -> Promise {
        require_gas();
        let (owner, mut v, pi) = self.pocket_entry();
        require!(!v.frozen, "vault frozen");
        check_text(&reason, "reason");
        require_not_self(&recipient);
        let now = env::block_timestamp();
        check_payment(&v.pockets[pi], &token, amount.0, &recipient, now).unwrap_or_else(|e| env::panic_str(e));
        require!(v.balance(&token) >= amount.0, "insufficient vault balance");
        let ws = charge_window(&mut v.pockets[pi], now, amount.0);
        let pocket = v.pockets[pi].name.clone();
        let promise = start_payout(
            &mut v,
            &owner,
            Kind::Spend,
            Some(pocket.clone()),
            &token,
            &recipient,
            amount.0,
            reason.clone(),
            ws,
            None,
            now,
        );
        self.save(&owner, v);
        emit(
            "spend",
            json!({ "owner": owner, "pocket": pocket, "token": token, "amount": amount, "recipient": recipient, "reason": reason }),
        );
        promise
    }

    /// Called with a pocket key to ask the owner for something the caps do not allow. Stores a request, pays nothing.
    pub fn request(&mut self, token: String, amount: U128, recipient: AccountId, reason: String) -> u64 {
        let (owner, mut v, pi) = self.pocket_entry();
        require!(!v.frozen, "vault frozen");
        check_text(&reason, "reason");
        require_not_self(&recipient);
        let now = env::block_timestamp();
        pocket_live(&v.pockets[pi], now).unwrap_or_else(|e| env::panic_str(e));
        require!(v.pockets[pi].token == token, "wrong token for this pocket");
        require!(amount.0 > 0, "amount is zero");
        v.drop_expired_requests(now);
        require!(v.requests.len() < MAX_REQUESTS, "too many pending requests (10)");
        let id = v.take_id();
        let pocket = v.pockets[pi].name.clone();
        v.requests.push(Request {
            id,
            pocket: pocket.clone(),
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            reason: reason.clone(),
            created_ns: U64(now),
        });
        self.save(&owner, v);
        emit(
            "request",
            json!({ "owner": owner, "request_id": id, "pocket": pocket, "token": token, "amount": amount,
                    "recipient": recipient, "reason": reason }),
        );
        id
    }

    // ------------------------------------------------ requests (owner)

    /// The owner's decision overrides the pocket's caps and allowlist, but not a frozen vault.
    #[payable]
    pub fn approve(&mut self, request_id: u64) -> Promise {
        require_gas();
        let (owner, mut v) = self.owner_entry();
        require!(!v.frozen, "vault frozen");
        let now = env::block_timestamp();
        let i = v.requests.iter().position(|r| r.id == request_id).unwrap_or_else(|| env::panic_str("no such request"));
        let r = v.requests[i].clone();
        require!(now < r.created_ns.0.saturating_add(REQUEST_TTL_NS), "request expired");
        require!(v.balance(&r.token) >= r.amount.0, "insufficient vault balance");
        require_not_self(&r.recipient);
        v.requests.remove(i);
        let promise = start_payout(
            &mut v,
            &owner,
            Kind::Approved,
            Some(r.pocket.clone()),
            &r.token,
            &r.recipient,
            r.amount.0,
            r.reason.clone(),
            0,
            None,
            now,
        );
        self.save(&owner, v);
        emit("approved", json!({ "owner": owner, "request_id": request_id, "amount": r.amount, "recipient": r.recipient }));
        promise
    }

    #[payable]
    pub fn reject(&mut self, request_id: u64) {
        let (owner, mut v) = self.owner_entry();
        let i = v.requests.iter().position(|r| r.id == request_id).unwrap_or_else(|| env::panic_str("no such request"));
        v.requests.remove(i);
        self.save(&owner, v);
        emit("rejected", json!({ "owner": owner, "request_id": request_id }));
    }

    // ------------------------------------------------ freeze / withdraw (owner)

    #[payable]
    pub fn freeze(&mut self) {
        self.set_frozen(true);
    }

    #[payable]
    pub fn unfreeze(&mut self) {
        self.set_frozen(false);
    }

    /// Always allowed, also while frozen. Sends to the owner's own account only. `amount` None = everything.
    #[payable]
    pub fn withdraw(&mut self, token: String, amount: Option<U128>) -> Promise {
        require_gas();
        let (owner, mut v) = self.owner_entry();
        let amt = amount.map_or_else(|| v.balance(&token), |a| a.0);
        require!(amt > 0, "nothing to withdraw");
        let now = env::block_timestamp();
        let promise = start_payout(&mut v, &owner, Kind::Withdraw, None, &token, &owner, amt, String::new(), 0, None, now);
        self.save(&owner, v);
        emit("withdraw", json!({ "owner": owner, "token": token, "amount": U128(amt) }));
        promise
    }

    // ------------------------------------------------ settlement callback

    /// Runs after the transfer. If it failed, puts back the balance, the pocket window and the order schedule.
    #[private]
    pub fn on_payout(&mut self, settle: Settle) {
        require!(env::promise_results_count() == 1, "expected one promise result");
        let ok = matches!(env::promise_result(0), PromiseResult::Successful(_));
        let mut v = match self.vaults.get(&settle.owner) {
            Some(v) => v.clone(),
            None => {
                env::log_str("on_payout: vault no longer exists");
                return;
            }
        };
        v.pending_out = v.pending_out.saturating_sub(1);
        if !ok {
            v.credit(&settle.token, settle.amount.0);
            v.mark_receipt_failed(settle.receipt_id);
            if let Some(name) = &settle.pocket {
                if let Some(p) = v.pockets.iter_mut().find(|p| p.name == *name) {
                    if settle.window_start.0 != 0 && p.window_start == settle.window_start {
                        p.spent = U128(p.spent.0.saturating_sub(settle.amount.0));
                    }
                }
            }
            if let Some(before) = settle.order_before.clone() {
                match v.orders.iter().position(|o| o.id == before.id) {
                    Some(i) => {
                        v.orders[i].next_due_ns = before.next_due_ns;
                        v.orders[i].remaining = before.remaining;
                    }
                    None => {
                        if v.orders.len() < MAX_ORDERS && v.pockets.iter().any(|p| p.name == before.pocket) {
                            v.orders.push(before);
                        }
                    }
                }
            }
            emit(
                "payout_failed",
                json!({ "owner": settle.owner, "token": settle.token, "amount": settle.amount, "receipt_id": settle.receipt_id }),
            );
        }
        self.save(&settle.owner, v);
    }

    // ------------------------------------------------ views

    pub fn version(&self) -> String {
        VERSION.to_string()
    }

    pub fn storage_cost(&self) -> U128 {
        U128(STORAGE_DEPOSIT)
    }

    pub fn get_tokens(&self) -> Vec<String> {
        self.tokens.clone()
    }

    pub fn owners_count(&self) -> u32 {
        self.owners.len()
    }

    pub fn get_vault(&self, owner: AccountId) -> Option<VaultView> {
        self.vaults.get(&owner).map(|v| VaultView {
            owner: owner.clone(),
            frozen: v.frozen,
            balances: v.balances.clone(),
            pockets: v.pockets.len() as u32,
            orders: v.orders.len() as u32,
            requests: v.requests.len() as u32,
            receipts_total: v.receipts_total,
            pending_out: v.pending_out,
            storage_paid: v.storage_paid,
        })
    }

    pub fn get_pockets(&self, owner: AccountId) -> Vec<Pocket> {
        self.vaults.get(&owner).map(|v| v.pockets.clone()).unwrap_or_default()
    }

    pub fn get_orders(&self, owner: AccountId) -> Vec<Order> {
        self.vaults.get(&owner).map(|v| v.orders.clone()).unwrap_or_default()
    }

    /// Pending requests that have not expired yet.
    pub fn get_requests(&self, owner: AccountId) -> Vec<Request> {
        let now = env::block_timestamp();
        self.vaults
            .get(&owner)
            .map(|v| v.requests.iter().filter(|r| now < r.created_ns.0.saturating_add(REQUEST_TTL_NS)).cloned().collect())
            .unwrap_or_default()
    }

    /// Last 50 receipts, oldest first.
    pub fn get_receipts(&self, owner: AccountId) -> Vec<Receipt> {
        self.vaults.get(&owner).map(|v| v.receipts_in_order()).unwrap_or_default()
    }

    /// Orders that execute_order would accept right now. `from_index` and `limit` count OWNERS (limit is capped at 20),
    /// so page through with from_index += limit until from_index >= owners_count().
    pub fn due_orders(&self, from_index: u32, limit: u32) -> Vec<DueOrder> {
        let now = env::block_timestamp();
        let end = from_index.saturating_add(limit.min(MAX_PAGE)).min(self.owners.len());
        let mut out = vec![];
        let mut i = from_index;
        while i < end {
            if let Some(owner) = self.owners.get(i) {
                if let Some(v) = self.vaults.get(owner) {
                    for o in &v.orders {
                        if check_order(v, o, now).is_ok() {
                            out.push(DueOrder {
                                owner: owner.clone(),
                                order_id: o.id,
                                pocket: o.pocket.clone(),
                                token: o.token.clone(),
                                amount: o.amount,
                                recipient: o.recipient.clone(),
                                next_due_ns: o.next_due_ns,
                            });
                        }
                    }
                }
            }
            i += 1;
        }
        out
    }
}

impl Guard {
    fn set_paused(&mut self, name: String, paused: bool) {
        let (owner, mut v) = self.owner_entry();
        let p = v.pockets.iter_mut().find(|p| p.name == name).unwrap_or_else(|| env::panic_str("no such pocket"));
        p.paused = paused;
        self.save(&owner, v);
    }

    fn set_frozen(&mut self, frozen: bool) {
        let (owner, mut v) = self.owner_entry();
        v.frozen = frozen;
        self.save(&owner, v);
        emit("frozen", json!({ "owner": owner, "frozen": frozen }));
    }
}

#[cfg(test)]
mod tests;
