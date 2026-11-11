import Foundation
import HermitCore

// Batch sends on Solana: SOL or one SPL token to many recipients, behind the same review as an EVM batch.
//
// What is different from EVM (BatchSend.swift):
// - There are no nonces to sign ahead. A Solana transfer carries a recent blockhash that expires after about a minute,
//   so a long list can't be signed in one go and sent slowly. One Face ID / Touch ID unlocks the key for the run, and
//   each transfer is then built, signed, sent and confirmed in turn. The key is held only in a wiped buffer
//   (SecretBytes) for the length of the run and signs nothing but the rows of the approved plan.
// - A recipient without a token account for the mint needs one. The transfer creates it (idempotently, in the same
//   transaction) and the sender pays its rent, about 0.002 SOL. The review shows that per row and in the total, and
//   only rows the review priced that way ever create an account.
// - Any failure stops the run. Rows before it are sent, the failed one says why, the rest never started, and Retry
//   (a new Face ID / Touch ID) sends what is left.
// - A transfer that was broadcast and can't be confirmed is never sent again while it could still land: it is only
//   treated as not sent once the chain is past the last block its blockhash was valid for.
//
// Not handled: Token-2022 mints (transfer fees and hooks change what arrives), .sol names.

// MARK: - What the plan keeps

/// The Solana side of a batch plan: what the review showed for fees and rent, and the priority price every transfer
/// of the batch is signed with (so a transfer never costs more than the review said).
public struct SolanaBatchInfo: Codable, Sendable, Equatable {
    /// The token's mint; nil for SOL.
    public var mint: String?
    /// Micro-lamports per compute unit, fixed when the batch was reviewed.
    public var priorityPrice: UInt64
    /// Network fee of one transfer, in lamports.
    public var feePlain: UInt64
    /// Network fee of a transfer that also creates the recipient's token account.
    public var feeWithAccount: UInt64
    /// One-time rent for a new token account, in lamports (paid by the sender).
    public var rentPerAccount: UInt64
    /// Recipients that had no token account at review time.
    public var newAccounts: Int
    /// All network fees and all account rent of the valid rows, in lamports.
    public var feeTotal: UInt64
    public var rentTotal: UInt64
    /// Lamports that have to stay in the sender's wallet (the rent-exempt minimum of an account).
    public var keep: UInt64

    public init(mint: String?, priorityPrice: UInt64, feePlain: UInt64, feeWithAccount: UInt64, rentPerAccount: UInt64, newAccounts: Int,
                feeTotal: UInt64, rentTotal: UInt64, keep: UInt64) {
        self.mint = mint; self.priorityPrice = priorityPrice; self.feePlain = feePlain; self.feeWithAccount = feeWithAccount
        self.rentPerAccount = rentPerAccount; self.newAccounts = newAccounts; self.feeTotal = feeTotal; self.rentTotal = rentTotal; self.keep = keep
    }

    public var feeTotalText: String { SolanaBatch.sol(feeTotal) }
    public var rentTotalText: String { SolanaBatch.sol(rentTotal) }
    public var rentEachText: String { SolanaBatch.sol(rentPerAccount) }
}

extension BatchPlan {
    /// Where a row's transaction can be looked at: Solscan for Solana, the network's own explorer otherwise.
    public func transactionURL(_ hash: String) -> URL? {
        guard let c = chain else { return nil }
        if c.kind == .solana { return URL(string: "https://solscan.io/tx/\(hash)" + (c.isTestnet ? "?cluster=devnet" : "")) }
        return c.explorerURL(tx: hash)
    }

    /// Everything a Solana batch takes out of the wallet: the amounts, every network fee and the rent for new token
    /// accounts. "25 USDC + 0.00412886 SOL", or one SOL figure when the batch itself is SOL. nil on other networks.
    public var solanaTotalText: String? {
        guard let s = solana else { return nil }
        if tokenAddress == nil {
            let amount = (try? Units.parse(total, decimals: decimals)) ?? 0
            return "\(Units.format(amount + UInt128(s.feeTotal), decimals: 9)) \(symbol)"
        }
        return "\(total) \(symbol) + \(SolanaBatch.sol(s.feeTotal + s.rentTotal)) SOL"
    }
}

// MARK: - Checking a list (no network in here)

public enum SolanaBatch {
    /// The most recipients in one Solana batch.
    public static let maxRecipients = 50
    /// Lamports per signature.
    public static let baseFee: UInt64 = 5_000
    /// Compute limits by kind of transfer. Real use is about 450 units for SOL, 6,500 for a token transfer and 30,000 to
    /// 40,000 when the token account is created too; the priority fee is charged on the limit, so it stays close.
    static let unitsSOL: UInt32 = 1_500
    static let unitsToken: UInt32 = 30_000
    static let unitsTokenNewAccount: UInt32 = 100_000
    /// Blocks past a transfer's last valid height before it is called expired (never landed).
    public static let expiryMargin: UInt64 = 32
    /// JSON-RPC answers to sendTransaction that mean the node did not broadcast it: its preflight run failed (-32002),
    /// the signature didn't verify (-32003), or the request itself was malformed. Any other error leaves it open whether
    /// the transfer went out, so the sender tracks it instead of calling it unsent.
    static let refusals: Set<Int> = [-32002, -32003, -32600, -32601, -32602, -32700]

    /// The token of a batch. `usd` is the price per whole token when the caller knows one (a held token, from Jupiter).
    public struct Token: Sendable, Equatable {
        public let mint: String
        public let symbol: String
        public let decimals: Int
        public let usd: Decimal?
        public let verified: Bool
        public init(mint: String, symbol: String, decimals: Int, usd: Decimal? = nil, verified: Bool = true) {
            self.mint = mint; self.symbol = symbol; self.decimals = decimals; self.usd = usd; self.verified = verified
        }
    }

    /// What kind of account a recipient address is on chain.
    public enum Owner: Sendable, Equatable {
        /// Nothing there yet: a new wallet, when the address is a real key.
        case missing
        /// A normal wallet (owned by the System program).
        case wallet
        /// A token account or a mint: money sent "to" it as a wallet would be lost.
        case tokenAccount
        /// A program, or an account a program owns.
        case program
    }

    /// The recipient's token account for the batch's mint.
    public enum TokenAccount: Sendable, Equatable { case missing, ready, frozen, unusable }

    /// One line of the list after the checks that need no network.
    public struct Draft: Sendable, Equatable {
        public let line: Int
        public let input: String
        /// Canonical base58 ("" when it isn't a Solana address).
        public let address: String
        public let amountText: String
        /// Base units (0 when the row has a problem).
        public let value: UInt64
        public var problem: String?
    }

    /// What the chain said, read once for the review.
    public struct Facts: Sendable, Equatable {
        /// The sender's SOL, in lamports.
        public var lamports: UInt64
        /// The sender's balance of the token (its associated token account), in base units.
        public var tokenBalance: UInt128
        public var senderTokenFrozen: Bool
        /// Rent-exempt minimum of an empty account: the least a new address must receive, and what the sender must keep.
        public var rentWallet: UInt64
        /// Rent for one token account (165 bytes).
        public var rentTokenAccount: UInt64
        /// Micro-lamports per compute unit.
        public var priorityPrice: UInt64
        public var owners: [String: Owner]
        public var tokenAccounts: [String: TokenAccount]
        public init(lamports: UInt64, tokenBalance: UInt128 = 0, senderTokenFrozen: Bool = false, rentWallet: UInt64 = 890_880,
                    rentTokenAccount: UInt64 = 2_039_280, priorityPrice: UInt64 = 1_000, owners: [String: Owner] = [:],
                    tokenAccounts: [String: TokenAccount] = [:]) {
            self.lamports = lamports; self.tokenBalance = tokenBalance; self.senderTokenFrozen = senderTokenFrozen; self.rentWallet = rentWallet
            self.rentTokenAccount = rentTokenAccount; self.priorityPrice = priorityPrice; self.owners = owners; self.tokenAccounts = tokenAccounts
        }
    }

    /// The spending policy's numbers when the batch is reviewed.
    public struct Limits: Sendable, Equatable {
        /// Dollars per whole token; nil when there is no price.
        public var unitUSD: Decimal?
        public var dailyLeft: Decimal
        public var dailyLimit: Decimal
        public var agentCap: Decimal
        public init(unitUSD: Decimal?, dailyLeft: Decimal, dailyLimit: Decimal, agentCap: Decimal) {
            self.unitUSD = unitUSD; self.dailyLeft = dailyLeft; self.dailyLimit = dailyLimit; self.agentCap = agentCap
        }
    }

    /// What this device knows about an address: past payments, a saved label, and the Whitelist only rule.
    public struct Book {
        public var payments: (String) -> Int
        public var saved: (String) -> Bool
        public var whitelistBlock: (String) -> String?
        public init(payments: @escaping (String) -> Int = { _ in 0 }, saved: @escaping (String) -> Bool = { _ in false },
                    whitelistBlock: @escaping (String) -> String? = { _ in nil }) {
            self.payments = payments; self.saved = saved; self.whitelistBlock = whitelistBlock
        }
    }

    /// Lamports as SOL, exact ("0.00203928").
    public static func sol(_ lamports: UInt64) -> String { Units.format(UInt128(lamports), decimals: 9) }

    /// Network fee of one transaction: the signature fee plus the priority fee on its compute limit, rounded up.
    public static func fee(units: UInt32, price: UInt64) -> UInt64 { baseFee + (UInt64(units) * price + 999_999) / 1_000_000 }

    /// An error in words.
    static func reason(_ error: Error) -> String { (error as? WalletError)?.errorDescription ?? error.localizedDescription }

    /// Rows checked without the network: a real Solana address, not this wallet, not listed twice, a positive amount
    /// with no more decimals than the token has. Amounts are parsed exactly as given, never rounded.
    public static func drafts(_ recipients: [(address: String, amount: String)], sender: SolanaPublicKey, mint: String?, symbol: String,
                              decimals: Int, fromPicture: Bool = false, book: Book = Book()) -> [Draft] {
        var out: [Draft] = [], seen: [String: Int] = [:]
        for (i, r) in recipients.enumerated() {
            let input = r.address.trimmingCharacters(in: .whitespacesAndNewlines)
            // Thousands commas ("1,000") go; any other comma ("25,5") makes the row unclear, never a bigger amount.
            let rawAmount = r.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountText = RecipientTable.ungrouped(rawAmount) ?? ""
            var problem: String?, address = ""
            if let k = SolanaPublicKey(input) {
                address = k.description
                // A Solana address has no checksum, so a character misread from a picture still parses. Only addresses
                // already saved or paid before get through from a picture.
                let known = book.saved(address) || book.payments(address) > 0
                if fromPicture && !known { problem = "Read from a picture, and Solana addresses have no checksum. Paste this address instead." }
                else if k == sender { problem = "That's this wallet" }
                else if address == mint { problem = "That's the token itself, not a wallet" }
                else if let first = seen[address] { problem = "Same address as row \(first)" }
                else if let block = book.whitelistBlock(address) { problem = block }
                else { seen[address] = i + 1 }
            } else if input.lowercased().hasSuffix(".sol") {
                problem = "Names aren't looked up in a batch; use the address"
            } else if input.hasPrefix("0x") || input.hasPrefix("0X") {
                problem = "That's an EVM address, not a Solana one"
            } else {
                problem = "Not a Solana address"
            }
            var value: UInt64 = 0
            if problem == nil {
                if amountText.isEmpty && !rawAmount.isEmpty { problem = "Unclear amount. Write it with a dot, like 25.5" }
                else if amountText.isEmpty { problem = "No amount" }
                else if let v = try? Units.parse(amountText, decimals: decimals), v > 0, let small = UInt64(exactly: v) { value = small }
                else { problem = "Amount \(amountText) isn't valid for \(symbol)" }
            }
            out.append(Draft(line: i + 1, input: input, address: address, amountText: amountText, value: value, problem: problem))
        }
        return out
    }

    /// The reviewed plan: every row against what the chain said about it, then the total, the network fees, the rent for
    /// new token accounts, the balances that have to cover all of it, and the spending policy on the batch total.
    /// Nothing is signed or sent here.
    public static func review(id: String = UUID().uuidString, walletID: UUID, chain: Chain, token: Token?, drafts: [Draft], facts: Facts,
                              limits: Limits, book: Book = Book(), origin: ActionOrigin, source: String? = nil, fromPicture: Bool = false,
                              created: Date = Date()) -> BatchPlan {
        let sym = token?.symbol ?? chain.nativeSymbol
        let decimals = token?.decimals ?? chain.nativeDecimals
        let feePlain = fee(units: token == nil ? unitsSOL : unitsToken, price: facts.priorityPrice)
        let feeNew = fee(units: unitsTokenNewAccount, price: facts.priorityPrice)

        var rows: [BatchRow] = []
        var total: UInt128 = 0, feeTotal: UInt64 = 0
        var newAccounts = 0, validCount = 0
        for d in drafts {
            var problem = d.problem
            var needsAccount = false
            if problem == nil {
                switch facts.owners[d.address] {
                case .wallet?:
                    // System-owned, but at an address no key signs for (a program's vault, a multisig): what is sent there
                    // moves again only if that program lets it. Never by the way, in a list.
                    if SolanaPublicKey(d.address)?.isOnCurve != true {
                        problem = "A program controls this address (a vault or multisig), not a key. Send to it on its own from Wallets"
                    }
                case .missing?:
                    // Nothing at the address yet. A real key is a new wallet; anything else can never be spent from.
                    if SolanaPublicKey(d.address)?.isOnCurve != true { problem = "Not a wallet address: no key can sign for it" }
                    else if token == nil, d.value < facts.rentWallet { problem = "A new address needs at least \(sol(facts.rentWallet)) SOL to open" }
                case .tokenAccount?: problem = "That's a token account, not a wallet. Use its owner's wallet address"
                case .program?: problem = "That's a program's account, not a wallet"
                case nil: problem = "Couldn't check this address. Try again"
                }
            }
            if problem == nil, token != nil {
                switch facts.tokenAccounts[d.address] {
                case .ready?: break
                case .missing?: needsAccount = true
                case .frozen?: problem = "Their \(sym) account is frozen"
                case .unusable?: problem = "Their \(sym) account can't take a transfer"
                case nil: problem = "Couldn't check this address. Try again"
                }
            }
            var row = BatchRow(line: d.line, input: d.input, address: d.address, amount: d.amountText, problem: problem,
                               status: problem == nil ? .ready : .invalid)
            if problem == nil {
                validCount += 1
                total += UInt128(d.value)
                feeTotal += needsAccount ? feeNew : feePlain
                if needsAccount { newAccounts += 1 }
                if token != nil { row.needsAccount = needsAccount }
            }
            rows.append(row)
        }
        let rentTotal = facts.rentTokenAccount * UInt64(newAccounts)

        var checks: [String] = [], warnings: [String] = [], blocks: [String] = []
        if fromPicture { warnings.append("Read from a picture. Compare every address with the original.") }
        if let t = token, !t.verified { warnings.append("\(sym) isn't on Jupiter's verified list. Mint \(t.mint). Check it's the token you mean.") }
        if validCount == 0 { blocks.append("None of the rows can be sent.") }
        let bad = rows.count - validCount
        if bad > 0 { warnings.append("\(bad) row\(bad == 1 ? "" : "s") left out (listed below with the reason).") }
        else { checks.append("Every address is a wallet, no duplicates") }

        // Balances: the amounts, every network fee, the rent for new token accounts, and what must stay in the wallet.
        if validCount > 0 {
            let fees = "\(validCount) network fee\(validCount == 1 ? "" : "s")"
            if token != nil {
                if facts.senderTokenFrozen {
                    blocks.append("Your \(sym) is frozen by the token's issuer, so it can't be sent.")
                } else if facts.tokenBalance < total {
                    blocks.append("Not enough \(sym): the list needs \(Units.format(total, decimals: decimals)), this wallet has \(Units.format(facts.tokenBalance, decimals: decimals)).")
                } else { checks.append("Balance covers the total") }
                let out = feeTotal + rentTotal
                if UInt128(facts.lamports) < UInt128(out) + UInt128(facts.rentWallet) {
                    let rent = newAccounts == 0 ? "" : " and rent for \(newAccounts) new \(sym) account\(newAccounts == 1 ? "" : "s")"
                    blocks.append("Not enough SOL on \(chain.name): \(fees)\(rent) come to \(sol(out)) SOL, and \(sol(facts.rentWallet)) SOL has to stay in the wallet. It has \(sol(facts.lamports)) SOL.")
                } else {
                    checks.append(newAccounts == 0 ? "SOL covers \(fees)" : "SOL covers \(fees) and rent for \(newAccounts) new \(sym) account\(newAccounts == 1 ? "" : "s")")
                }
            } else {
                let out = total + UInt128(feeTotal)
                if UInt128(facts.lamports) < out + UInt128(facts.rentWallet) {
                    blocks.append("Not enough SOL: the list and its \(fees) come to \(Units.format(out, decimals: 9)) SOL, and \(sol(facts.rentWallet)) SOL has to stay in the wallet. It has \(sol(facts.lamports)) SOL.")
                } else { checks.append("Balance covers the total and \(fees)") }
            }
        }
        if newAccounts > 0 {
            warnings.append("\(newAccounts) recipient\(newAccounts == 1 ? " has" : "s have") no \(sym) account yet. Opening one costs you \(sol(facts.rentTokenAccount)) SOL each, once.")
        }

        // Spending policy: the whole batch is one move, as for an EVM batch.
        let usd: Decimal? = limits.unitUSD.flatMap { u in Decimal(string: Units.format(total, decimals: decimals)).map { $0 * u } }
        if let usd {
            if usd > limits.dailyLeft { blocks.append("Over your daily limit: \(SpendPolicy.money(limits.dailyLeft)) of \(SpendPolicy.money(limits.dailyLimit)) left today.") }
            else { checks.append("Within daily limit (\(SpendPolicy.money(limits.dailyLeft - usd)) left today)") }
        } else if origin == .agent {
            blocks.append("The assistant can't send tokens without a price. Send \(sym) from Wallets yourself.")
        } else if chain.isTestnet {
            warnings.append("Test coins have no price, so this isn't counted toward your \(SpendPolicy.money(limits.dailyLimit)) daily limit.")
        } else {
            blocks.append("There is no price for \(sym) right now, so this can't be checked against your \(SpendPolicy.money(limits.dailyLimit)) daily limit. Try again in a minute.")
        }
        if origin == .agent, let usd {
            if usd > limits.agentCap { blocks.append("The assistant can prepare up to \(SpendPolicy.money(limits.agentCap)) per move. Attach the list and ask again, or split it.") }
            else { checks.append("Under the assistant's \(SpendPolicy.money(limits.agentCap)) per-move cap") }
        }
        let fresh = rows.filter { $0.status == .ready && book.payments($0.address) == 0 }.count
        if fresh > 0 { warnings.append("\(fresh) address\(fresh == 1 ? " is" : "es are") new to this wallet. Check the list.") }
        else if validCount > 0 { checks.append("Paid every address before") }
        checks.append("Sent one after another, each confirmed before the next")
        checks.append("Signed on this device with one \(validCount == 1 ? "approval" : "approval for all \(validCount)")")

        let info = SolanaBatchInfo(mint: token?.mint, priorityPrice: facts.priorityPrice, feePlain: feePlain, feeWithAccount: feeNew,
                                   rentPerAccount: facts.rentTokenAccount, newAccounts: newAccounts, feeTotal: feeTotal, rentTotal: rentTotal,
                                   keep: facts.rentWallet)
        return BatchPlan(id: id, walletID: walletID, chainID: chain.id, symbol: sym, tokenAddress: token?.mint, decimals: decimals, rows: rows,
                         total: Units.format(total, decimals: decimals), feeText: "\(sol(feeTotal)) SOL", gasLimit: 0, checks: checks,
                         warnings: warnings, blocks: blocks, origin: origin, source: source, created: created,
                         unitUSD: limits.unitUSD.map { "\($0)" }, solana: info)
    }

    // MARK: Reading the node's answers

    static func owner(_ s: SolanaAccountSummary?) -> Owner {
        guard let s else { return .missing }
        if s.executable { return .program }
        if s.owner == SolanaPrograms.system { return .wallet }
        if s.owner == SolanaPrograms.token || s.owner == SolanaPrograms.token2022 { return .tokenAccount }
        return .program
    }

    /// The account at an owner's associated token address: there and usable for this mint, frozen, something else, or
    /// not there yet.
    static func tokenAccount(_ s: SolanaAccountSummary?, mint: String, owner: String) -> TokenAccount {
        guard let s else { return .missing }
        guard s.owner == SolanaPrograms.token, s.parsedType == "account", s.tokenMint == mint, s.tokenOwner == owner else { return .unusable }
        return s.tokenState == "frozen" ? .frozen : .ready
    }

    // MARK: One row's transaction

    /// The instructions of one row: the compute budget, the recipient's token account when the review priced it, and the
    /// transfer itself (transferChecked with the mint's decimals, or a System transfer for SOL).
    static func instructions(from: SolanaPublicKey, to: SolanaPublicKey, amount: UInt64, mint: SolanaPublicKey?, decimals: Int,
                             createAccount: Bool, price: UInt64) -> [SolanaInstruction] {
        guard let mint else {
            return [.setComputeUnitLimit(unitsSOL), .setComputeUnitPrice(price), .transfer(from: from, to: to, lamports: amount)]
        }
        let source = SolanaPublicKey.associatedTokenAccount(owner: from, mint: mint)
        let destination = SolanaPublicKey.associatedTokenAccount(owner: to, mint: mint)
        var out: [SolanaInstruction] = [.setComputeUnitLimit(createAccount ? unitsTokenNewAccount : unitsToken), .setComputeUnitPrice(price)]
        if createAccount { out.append(.createAssociatedTokenAccountIdempotent(payer: from, owner: to, mint: mint)) }
        out.append(.transferChecked(source: source, mint: mint, destination: destination, owner: from, amount: amount,
                                    decimals: UInt8(clamping: decimals)))
        return out
    }

    /// Reads built instructions back: exactly one transfer, of exactly this amount, from this wallet to this recipient.
    static func says(_ ixs: [SolanaInstruction], from: SolanaPublicKey, to: SolanaPublicKey, amount: UInt64, mint: SolanaPublicKey?,
                     decimals: Int) -> Bool {
        let moves = ixs.filter { $0.program == .systemProgram || $0.program == .tokenProgram }
        guard moves.count == 1, let last = ixs.last, last == moves[0] else { return false }
        let le = amount.littleEndianBytes(width: 8)
        if let mint {
            guard last.program == .tokenProgram, last.accounts.count == 4, last.data == [12] + le + [UInt8(clamping: decimals)] else { return false }
            return last.accounts[0].key == SolanaPublicKey.associatedTokenAccount(owner: from, mint: mint) && last.accounts[1].key == mint
                && last.accounts[2].key == SolanaPublicKey.associatedTokenAccount(owner: to, mint: mint) && last.accounts[3].key == from
        }
        guard last.program == .systemProgram, last.accounts.count == 2, last.data == [2, 0, 0, 0] + le else { return false }
        return last.accounts[0].key == from && last.accounts[1].key == to
    }

    /// A node's refusal in plain words.
    static func plain(_ error: Error) -> String {
        let text = reason(error)
        let low = text.lowercased()
        if low.contains("blockhash not found") { return "The network didn't take it in time" }
        if low.contains("insufficient lamports") || low.contains("insufficient funds for rent") { return "Not enough SOL for the fee or the account rent" }
        // SPL Token's own errors: 0x11 is a frozen account, 0x1 not enough tokens (matched whole, 0x1 is a prefix of 0x11).
        if low.contains("frozen") || low.contains("custom program error: 0x11") { return "The token account is frozen" }
        if low.contains("insufficient funds") || low.range(of: #"custom program error: 0x1\b"#, options: .regularExpression) != nil {
            return "Not enough balance for this transfer"
        }
        if low.contains("accountnotfound") || low.contains("invalidaccountdata") || low.contains("invalid account data") {
            return "The recipient's token account isn't there anymore. Prepare the list again"
        }
        return text
    }
}

// MARK: - The node a batch talks to

/// One account as the node reports it (jsonParsed), as far as a batch needs it.
public struct SolanaAccountSummary: Sendable, Equatable {
    /// The program that owns the account.
    public var owner: String
    public var lamports: UInt64
    public var executable: Bool
    /// "account" for a token account, "mint" for a mint; nil when the node didn't parse it.
    public var parsedType: String?
    public var tokenMint: String?
    public var tokenOwner: String?
    public var tokenAmount: UInt128?
    /// "initialized" or "frozen".
    public var tokenState: String?
    public var mintDecimals: Int?

    public init(owner: String, lamports: UInt64, executable: Bool = false, parsedType: String? = nil, tokenMint: String? = nil,
                tokenOwner: String? = nil, tokenAmount: UInt128? = nil, tokenState: String? = nil, mintDecimals: Int? = nil) {
        self.owner = owner; self.lamports = lamports; self.executable = executable; self.parsedType = parsedType; self.tokenMint = tokenMint
        self.tokenOwner = tokenOwner; self.tokenAmount = tokenAmount; self.tokenState = tokenState; self.mintDecimals = mintDecimals
    }

    /// nil for an account that doesn't exist. An answer that can't be read throws: it is never taken as "not there".
    static func parse(_ a: JSON) throws -> SolanaAccountSummary? {
        if a.isNull { return nil }
        guard let owner = a["owner"]?.string, let l = a["lamports"]?.double, l >= 0, let lamports = UInt64(exactly: l) else {
            throw WalletError.badResponse("account")
        }
        var s = SolanaAccountSummary(owner: owner, lamports: lamports, executable: a["executable"]?.bool ?? false)
        if let parsed = a["data"]?["parsed"] {
            let info = parsed["info"]
            s.parsedType = parsed["type"]?.string
            s.tokenMint = info?["mint"]?.string
            s.tokenOwner = info?["owner"]?.string
            s.tokenState = info?["state"]?.string
            s.tokenAmount = info?["tokenAmount"]?["amount"]?.string.flatMap { UInt128($0) }
            s.mintDecimals = info?["decimals"]?.int
        }
        return s
    }
}

public struct SolanaBlockhash: Sendable, Equatable {
    public var hash: [UInt8]
    /// The last block height a transaction with this blockhash can land in.
    public var lastValidBlockHeight: UInt64
    public init(hash: [UInt8], lastValidBlockHeight: UInt64) { self.hash = hash; self.lastValidBlockHeight = lastValidBlockHeight }
}

/// What the cluster says about a transaction: confirmed (it went through), included and failed (nothing moved), or
/// seen by the node but not confirmed yet (it can still land, so it is never treated as expired).
public enum SolanaSignatureStatus: Sendable, Equatable { case confirmed, failed(String), seen }

/// The calls a Solana batch makes. `SolanaClient` is the real one; tests hand in a fake.
public protocol SolanaBatchNode: Sendable {
    func lamports(of account: SolanaPublicKey) async throws -> UInt64
    /// One entry per key, nil where no account exists.
    func accountSummaries(_ keys: [SolanaPublicKey]) async throws -> [SolanaAccountSummary?]
    func rentExempt(bytes: Int) async throws -> UInt64
    /// Micro-lamports per compute unit.
    func priorityPrice(for accounts: [SolanaPublicKey]) async throws -> UInt64
    /// Runs the transaction without sending it. nil when it would go through, else why not.
    func dryRun(_ tx: SolanaTransaction) async throws -> String?
    func blockhash() async throws -> SolanaBlockhash
    func blockHeight() async throws -> UInt64
    /// Broadcasts a signed transaction and returns its signature.
    func submit(_ tx: SolanaTransaction) async throws -> String
    /// nil only when the node has never seen the signature. An answer that can't be read throws.
    func status(of signature: String) async throws -> SolanaSignatureStatus?
}

extension SolanaClient: SolanaBatchNode {
    public func lamports(of account: SolanaPublicKey) async throws -> UInt64 { try await balance(account) }

    public func accountSummaries(_ keys: [SolanaPublicKey]) async throws -> [SolanaAccountSummary?] {
        var out: [SolanaAccountSummary?] = []
        // getMultipleAccounts takes up to 100 keys a call.
        for start in stride(from: 0, to: keys.count, by: 100) {
            let chunk = Array(keys[start..<min(start + 100, keys.count)])
            let r = try await rpc.call("getMultipleAccounts", [.array(chunk.map { .string($0.description) }),
                                                               ["encoding": "jsonParsed", "commitment": "confirmed"]])
            guard let list = r["value"]?.array, list.count == chunk.count else { throw WalletError.badResponse("getMultipleAccounts") }
            for a in list { out.append(try SolanaAccountSummary.parse(a)) }
        }
        return out
    }

    public func rentExempt(bytes: Int) async throws -> UInt64 { try await rentExemptMinimum(bytes: bytes) }

    public func priorityPrice(for accounts: [SolanaPublicKey]) async throws -> UInt64 { try await priorityFee(accounts: accounts) }

    public func dryRun(_ tx: SolanaTransaction) async throws -> String? {
        let sim = try await simulate(tx, accounts: [])
        return sim.error.map { WalletService.solanaError($0, logs: sim.logs) }
    }

    public func blockhash() async throws -> SolanaBlockhash {
        let b = try await latestBlockhash()
        return SolanaBlockhash(hash: b.hash, lastValidBlockHeight: b.lastValidBlockHeight)
    }

    public func blockHeight() async throws -> UInt64 {
        try u64(try await rpc.call("getBlockHeight", [["commitment": "confirmed"]]), "getBlockHeight")
    }

    public func submit(_ tx: SolanaTransaction) async throws -> String { try await send(tx) }

    public func status(of signature: String) async throws -> SolanaSignatureStatus? {
        let r = try await rpc.call("getSignatureStatuses", [[.string(signature)], ["searchTransactionHistory": true]])
        // An answer that can't be read throws: it is never taken as "the network has not seen it" (that is what lets
        // an expired transfer be sent again).
        guard let list = r["value"]?.array, list.count == 1 else { throw WalletError.badResponse("getSignatureStatuses") }
        let st = list[0]
        if st.isNull { return nil }
        // Only a confirmed or finalized answer counts, for a success and for a failure alike. Known but not there yet
        // is its own answer.
        guard let level = st["confirmationStatus"]?.string, level == "confirmed" || level == "finalized" else { return .seen }
        if let e = st["err"], !e.isNull { return .failed("Failed on chain") }
        return .confirmed
    }
}

// MARK: - Sending, one after another

/// Sends the rows of a reviewed Solana batch in order. Each row gets a fresh blockhash, is signed, broadcast and then
/// waited for; the next one starts only after it is confirmed. The first failure stops the run.
public struct SolanaBatchSender: Sendable {
    public enum Event: Sendable, Equatable {
        /// Signed and about to be handed to the network (reported first, so a run that is cut short can't forget it).
        case broadcast
        case confirmed
        /// Not sent, or included and failed. Nothing moved for this row.
        case failed
        /// Broadcast, and neither confirmed nor expired in the time allowed. It may still land.
        case unconfirmed
        /// A row left unconfirmed by an earlier run turned out confirmed, or never landed.
        case settledConfirmed, settledFailed
    }

    let node: SolanaBatchNode
    /// Signs with the wallet's key. The caller unlocked it once for this run.
    let sign: @Sendable (SolanaTransaction) throws -> SolanaTransaction
    var pause: @Sendable (Duration) async throws -> Void
    var pollEvery: Duration
    /// Polls before a broadcast transfer is left as "not confirmed yet" (about four minutes at the default pace).
    var maxPolls: Int

    public init(node: SolanaBatchNode, sign: @escaping @Sendable (SolanaTransaction) throws -> SolanaTransaction,
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                pollEvery: Duration = .seconds(1.5), maxPolls: Int = 160) {
        self.node = node; self.sign = sign; self.pause = pause; self.pollEvery = pollEvery; self.maxPolls = maxPolls
    }

    static let expired = "It expired before reaching the chain. Nothing moved"
    static let unconfirmed = "Not confirmed yet"

    /// Rows an earlier run left as "sent": confirmed by now, failed, expired (their blockhash is too old to land, so
    /// nothing moved and they can go again), or still pending, which throws: nothing new is sent past a transfer that
    /// may still land. No key is needed for this.
    public static func settle(_ rows: [BatchRow], node: SolanaBatchNode,
                              update: @escaping @MainActor (BatchRow, Event) -> Void) async throws -> [BatchRow] {
        var out = rows
        for i in out.indices where out[i].status == .sent {
            guard let sig = out[i].hash else {
                out[i].status = .failed; out[i].error = "It was never broadcast"
                await update(out[i], .settledFailed)
                continue
            }
            // The height first, then the status: a transfer still unseen after its last valid block can't land later.
            let height = try await node.blockHeight()
            let status = try await node.status(of: sig)
            switch status {
            case .confirmed?:
                out[i].status = .confirmed; out[i].error = nil
                await update(out[i], .settledConfirmed)
            case .failed(let why)?:
                out[i].status = .failed; out[i].error = why
                await update(out[i], .settledFailed)
            case .seen?, nil:
                // Expired only when the node has never seen it and the chain is past its last valid block.
                guard status == nil, let last = out[i].lastValid, height > last + SolanaBatch.expiryMargin else {
                    throw WalletError.blocked("Row \(out[i].line) is still confirming, so nothing new was sent. Try again in a minute.")
                }
                out[i].status = .failed; out[i].error = expired; out[i].hash = nil; out[i].lastValid = nil
                await update(out[i], .settledFailed)
            }
        }
        return out
    }

    /// Sends what is left of `plan` (rows that are ready, or failed on an earlier try), in list order. Throws at the
    /// first row that doesn't go through, after reporting it; the rows after it are untouched and stay ready.
    public func run(_ plan: BatchPlan, from: SolanaPublicKey, update: @escaping @MainActor (BatchRow, Event) -> Void) async throws {
        guard let info = plan.solana else { throw WalletError.blocked("This batch can't be sent. Prepare it again.") }
        let mint = plan.tokenAddress.flatMap { SolanaPublicKey($0) }
        guard plan.tokenAddress == nil || mint != nil else { throw WalletError.unknownToken }
        let todo = plan.remaining
        let wentBefore = plan.valid.filter { $0.status == .confirmed }.count
        for (k, item) in todo.enumerated() {
            var row = item
            let went = wentBefore + k, left = todo.count - k - 1
            guard let to = SolanaPublicKey(row.address), let v = try? Units.parse(row.amount, decimals: plan.decimals),
                  let amount = UInt64(exactly: v), amount > 0 else {
                throw await stop(row, "This row can't be read anymore", went: went, left: left, update: update)
            }
            let ixs = SolanaBatch.instructions(from: from, to: to, amount: amount, mint: mint, decimals: plan.decimals,
                                               createAccount: row.needsAccount == true, price: info.priorityPrice)
            // Read our own instructions back: the transfer must say exactly what its row says.
            guard SolanaBatch.says(ixs, from: from, to: to, amount: amount, mint: mint, decimals: plan.decimals) else {
                throw await stop(row, "It didn't build as listed", went: went, left: left, update: update)
            }
            let bh: SolanaBlockhash
            do { bh = try await node.blockhash() } catch {
                throw await stop(row, SolanaBatch.plain(error), went: went, left: left, update: update)
            }
            let unsigned = SolanaTransaction(message: SolanaMessage(payer: from, instructions: ixs, recentBlockhash: bh.hash))
            let tx: SolanaTransaction
            do { tx = try sign(unsigned) } catch {
                throw await stop(row, "It couldn't be signed", went: went, left: left, update: update)
            }
            guard tx.verifySignature(), tx.message == unsigned.message else {
                throw await stop(row, "The signed transfer failed its self-check", went: went, left: left, update: update)
            }
            // The transaction's id is its signature, known before anything is sent.
            let sig = tx.signature
            // Reported as sent, with its id, before it is handed to the network: if the app stops right here, the saved
            // batch still knows this transfer and looks it up first (settle), instead of paying the row a second time.
            row.hash = sig; row.status = .sent; row.error = nil; row.lastValid = bh.lastValidBlockHeight
            await update(row, .broadcast)
            do {
                _ = try await node.submit(tx)
            } catch let WalletError.rpc(code, message) where SolanaBatch.refusals.contains(code) {
                // The node refused it before broadcasting (its own test run failed, a bad blockhash, a bad signature).
                row.hash = nil; row.lastValid = nil
                throw await stop(row, SolanaBatch.plain(WalletError.rpc(code: code, message: message)), went: went, left: left, update: update)
            } catch {
                // No clear answer (a timeout, a dropped connection, a node error after it took the transfer): it may have
                // gone out. It is tracked like a broadcast transfer, never treated as unsent.
            }

            switch await confirm(sig, lastValid: bh.lastValidBlockHeight) {
            case .confirmed:
                row.status = .confirmed
                await update(row, .confirmed)
            case .failed(let why):
                throw await stop(row, why, went: went, left: left, update: update)
            case .expired:
                row.hash = nil; row.lastValid = nil
                throw await stop(row, Self.expired, went: went, left: left, update: update)
            case .unknown:
                row.error = Self.unconfirmed
                await update(row, .unconfirmed)
                throw WalletError.blocked("Row \(row.line) was sent but isn't confirmed yet, so the rest are waiting. \(Self.tally(went: went, left: left)). Check its link, then try again.")
            }
        }
    }

    /// Marks the row failed, reports it, and returns the error that ends the run.
    private func stop(_ row: BatchRow, _ why: String, went: Int, left: Int,
                      update: @escaping @MainActor (BatchRow, Event) -> Void) async -> WalletError {
        var r = row
        r.status = .failed; r.error = why
        await update(r, .failed)
        return .blocked("Row \(row.line) failed: \(why). \(Self.tally(went: went, left: left)). Retry sends the rest after a new approval.")
    }

    /// "2 sent before it, 3 not started": what a stopped run leaves on either side of the row it stopped at.
    static func tally(went: Int, left: Int) -> String {
        let before = went == 0 ? "None sent before it" : "\(went) sent before it"
        let after = left == 0 ? "none after it" : "\(left) not started"
        return "\(before), \(after)"
    }

    private enum Outcome { case confirmed, failed(String), expired, unknown }
    private enum Look { case status(SolanaSignatureStatus), nothing, unreachable }

    private func look(_ sig: String) async -> Look {
        do {
            if let s = try await node.status(of: sig) { return .status(s) }
            return .nothing
        } catch { return .unreachable }
    }

    /// Waits for a broadcast transfer: confirmed, failed on chain, expired (the chain is past its last valid block and
    /// it never appeared), or unknown when the node gives no answer in the time allowed.
    private func confirm(_ sig: String, lastValid: UInt64) async -> Outcome {
        var polls = 0
        while polls < maxPolls {
            polls += 1
            if case .status(let s) = await look(sig) {
                switch s {
                case .confirmed: return .confirmed
                case .failed(let why): return .failed(why)
                case .seen: break
                }
            }
            // Every few polls: is the chain past the last block this transfer could land in?
            if polls % 4 == 0, let height = try? await node.blockHeight(), height > lastValid + SolanaBatch.expiryMargin {
                // One more look after the height: only a clear "never seen" makes it expired.
                switch await look(sig) {
                case .status(.confirmed): return .confirmed
                case .status(.failed(let why)): return .failed(why)
                case .nothing: return .expired
                case .status(.seen), .unreachable: break
                }
            }
            do { try await pause(pollEvery) } catch { return .unknown }
        }
        return .unknown
    }
}

// MARK: - The wallet's side

extension WalletService {
    /// Checks a Solana batch without signing anything: every address (a real wallet, not this one, not twice, not a
    /// token account), every amount, which recipients need a token account, the token and SOL balances against the
    /// total, the fees, the rent and what must stay in the wallet, one transfer simulated, and the spending policy.
    func planSolanaBatch(wallet w: WalletRecord, chain: Chain, symbol: String, recipients: [(address: String, amount: String)],
                         origin: ActionOrigin, source: String?, fromPicture: Bool, spl: SolanaBatch.Token?,
                         node given: SolanaBatchNode? = nil) async throws -> BatchPlan {
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Sends on \(chain.name) are off in this build.") }
        guard !recipients.isEmpty else { throw WalletError.blocked("No recipients in the list.") }
        guard recipients.count <= SolanaBatch.maxRecipients else {
            throw WalletError.blocked("That's \(recipients.count) recipients. A Solana batch takes up to \(SolanaBatch.maxRecipients); split the list.")
        }
        guard let from = SolanaPublicKey(w.solanaAddress) else { throw WalletError.vault("This wallet has no Solana address.") }

        // The token: SOL, one Hermit lists (USDC, USDT), or one the wallet holds that the caller looked up.
        var token: SolanaBatch.Token?
        var unit: Decimal?
        if symbol.caseInsensitiveCompare(chain.nativeSymbol) == .orderedSame {
            unit = await usdPerUnit(chain: chain, token: nil)
        } else if let t = chain.token(symbol) {
            token = SolanaBatch.Token(mint: t.address, symbol: t.symbol, decimals: t.decimals, usd: nil, verified: true)
            unit = await usdPerUnit(chain: chain, token: t)
        } else if let s = spl, !chain.isTestnet {
            token = s
            unit = s.usd
        } else {
            throw WalletError.unknownToken
        }
        let sym = token?.symbol ?? chain.nativeSymbol
        let decimals = token?.decimals ?? chain.nativeDecimals

        let book = SolanaBatch.Book(payments: { a in self.addressBook.entry(for: a, kind: .solana)?.payments ?? 0 },
                                    saved: { a in self.addressBook.entry(for: a, kind: .solana)?.label != nil },
                                    whitelistBlock: { a in self.whitelistBlock(chain: chain, to: a) })
        let drafts = SolanaBatch.drafts(recipients, sender: from, mint: token?.mint, symbol: sym, decimals: decimals,
                                        fromPicture: fromPicture, book: book)
        let keys: [SolanaPublicKey] = drafts.filter { $0.problem == nil }.compactMap { SolanaPublicKey($0.address) }

        // What the chain says: balances, rent, and what sits at every recipient's address (two or three calls in all).
        let node: SolanaBatchNode = given ?? sol(chain)
        let lamports = try await node.lamports(of: from)
        let rentWallet = try await node.rentExempt(bytes: 0)
        var facts = SolanaBatch.Facts(lamports: lamports, rentWallet: rentWallet, rentTokenAccount: 0, priorityPrice: 0)
        let owners = try await node.accountSummaries(keys)
        guard owners.count == keys.count else { throw WalletError.badResponse("accounts") }
        for (k, s) in zip(keys, owners) { facts.owners[k.description] = SolanaBatch.owner(s) }
        var mintKey: SolanaPublicKey?
        if let t = token {
            guard let mint = SolanaPublicKey(t.mint) else { throw WalletError.unknownToken }
            mintKey = mint
            facts.rentTokenAccount = try await node.rentExempt(bytes: 165)
            let mine = SolanaPublicKey.associatedTokenAccount(owner: from, mint: mint)
            let theirs = keys.map { SolanaPublicKey.associatedTokenAccount(owner: $0, mint: mint) }
            let states = try await node.accountSummaries([mint, mine] + theirs)
            guard states.count == theirs.count + 2 else { throw WalletError.badResponse("accounts") }
            // The mint itself: a classic SPL token with the decimals the amounts were read with.
            guard let m = states[0], m.parsedType == "mint" else { throw WalletError.blocked("\(t.symbol) isn't a token on \(chain.name).") }
            guard m.owner == SolanaPrograms.token else {
                throw WalletError.blocked(m.owner == SolanaPrograms.token2022
                    ? "\(t.symbol) is a Token-2022 token. Batch sends work with classic SPL tokens for now."
                    : "\(t.symbol) isn't a token Hermit can send.")
            }
            guard m.mintDecimals == t.decimals else { throw WalletError.blocked("\(t.symbol)'s decimals on chain don't match what Hermit has. Nothing was prepared.") }
            switch SolanaBatch.tokenAccount(states[1], mint: t.mint, owner: from.description) {
            case .ready: facts.tokenBalance = states[1]?.tokenAmount ?? 0
            case .frozen: facts.senderTokenFrozen = true
            case .missing, .unusable: facts.tokenBalance = 0
            }
            for (k, s) in zip(keys, states.dropFirst(2)) {
                facts.tokenAccounts[k.description] = SolanaBatch.tokenAccount(s, mint: t.mint, owner: k.description)
            }
            facts.priorityPrice = try await node.priorityPrice(for: [from, mint])
        } else {
            facts.priorityPrice = try await node.priorityPrice(for: [from])
        }

        let p = policy
        let limits = SolanaBatch.Limits(unitUSD: unit, dailyLeft: p.limit.remaining(), dailyLimit: p.limit.dailyLimitUSD, agentCap: p.agentCapUSD)
        var plan = SolanaBatch.review(walletID: w.id, chain: chain, token: token, drafts: drafts, facts: facts, limits: limits, book: book,
                                      origin: origin, source: source, fromPicture: fromPicture)

        // One transfer run on the node without sending it, as the review of an EVM batch does.
        if plan.blocks.isEmpty, let first = plan.rows.first(where: { $0.status == .ready }), let to = SolanaPublicKey(first.address),
           let v = try? Units.parse(first.amount, decimals: plan.decimals), let amount = UInt64(exactly: v) {
            let ixs = SolanaBatch.instructions(from: from, to: to, amount: amount, mint: mintKey, decimals: plan.decimals,
                                               createAccount: first.needsAccount == true, price: facts.priorityPrice)
            let draft = SolanaTransaction(message: SolanaMessage(payer: from, instructions: ixs, recentBlockhash: [UInt8](repeating: 0, count: 32)))
            do {
                if let why = try await node.dryRun(draft) { plan.blocks.append("Simulation failed: \(why)") }
                else { plan.checks.insert("A transfer simulated without errors", at: min(1, plan.checks.count)) }
            } catch {
                plan.blocks.append("Simulation failed: \(SolanaBatch.reason(error))")
            }
        }
        return plan
    }

    /// Sends what is left of a Solana batch. Rows an earlier run left unconfirmed are settled first (no key needed);
    /// then one Face ID / Touch ID unlocks the key for this run and the rows go out one after another, each confirmed
    /// before the next. The first failure stops it and throws, with every row's state already reported through `update`.
    func runSolanaBatch(_ plan: BatchPlan, node given: SolanaBatchNode? = nil,
                        pause: (@Sendable (Duration) async throws -> Void)? = nil,
                        update: @escaping @MainActor (BatchRow) -> Void) async throws {
        guard plan.blocks.isEmpty else { throw WalletError.blocked(plan.blocks.joined(separator: " ")) }
        guard let chain = plan.chain, chain.kind == .solana, let info = plan.solana else {
            throw WalletError.blocked("This batch can't be sent. Prepare it again.")
        }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet sends are off in this build.") }
        guard let w = wallets.first(where: { $0.id == plan.walletID }), let from = SolanaPublicKey(w.solanaAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let mint = plan.tokenAddress.flatMap { SolanaPublicKey($0) }
        guard plan.tokenAddress == nil || mint != nil else { throw WalletError.unknownToken }
        let node: SolanaBatchNode = given ?? sol(chain)

        // What each sent row adds to the daily limit, as for an EVM batch (a listed stablecoin counts at face value).
        let stable = plan.tokenAddress.map { a in chain.tokens.contains { $0.address == a && TokenTable.stableSymbols.contains($0.symbol) } } ?? false
        let unit: Decimal? = plan.unitUSD.flatMap { Decimal(string: $0) } ?? (stable ? Decimal(1) : nil)
        let log = sendLog, book = addressBook, limit = spendLimit
        let walletID = w.id, chainID = chain.id, symbol = plan.symbol
        // Rows an earlier run left as "not confirmed yet" were counted as spent then (line -> transaction id). A row left
        // as sent without that note comes from a run that was cut short before it could be counted.
        let counted: [Int: String] = Dictionary(plan.rows.filter { $0.status == .sent && $0.error == SolanaBatchSender.unconfirmed }
            .compactMap { r -> (Int, String)? in r.hash.map { (r.line, $0) } }, uniquingKeysWith: { a, _ in a })
        let report: @MainActor (BatchRow, SolanaBatchSender.Event) -> Void = { row, event in
            switch event {
            case .confirmed, .unconfirmed:
                // A row still unconfirmed may yet land, so it counts as spent; only a confirmed one marks the address as paid.
                if let h = row.hash {
                    log.record(SendLog.Entry(hash: h, chainID: chainID, walletID: walletID, amount: row.amount, symbol: symbol,
                                             recipient: row.address, label: nil, date: Date()))
                }
                if let unit, let amount = Decimal(string: row.amount) { limit.record(usd: amount * unit) }
                if event == .confirmed { book.recordPayment(to: row.address, kind: .solana) }
            case .settledConfirmed:
                // It landed. Counted now when the run that sent it never got to (the app was closed mid-run).
                if counted[row.line] == nil {
                    if let h = row.hash {
                        log.record(SendLog.Entry(hash: h, chainID: chainID, walletID: walletID, amount: row.amount, symbol: symbol,
                                                 recipient: row.address, label: nil, date: Date()))
                    }
                    if let unit, let amount = Decimal(string: row.amount) { limit.record(usd: amount * unit) }
                }
                book.recordPayment(to: row.address, kind: .solana)
            case .settledFailed:
                // Counted while it could still land, and it moved nothing: off the daily limit and out of Activity again.
                if let h = counted[row.line] {
                    log.remove(hash: h)
                    if let unit, let amount = Decimal(string: row.amount) { limit.refund(usd: amount * unit) }
                }
            case .broadcast, .failed:
                break
            }
            update(row)
        }

        var current = plan
        current.rows = try await SolanaBatchSender.settle(plan.rows, node: node, update: report)
        let todo = current.remaining
        guard !todo.isEmpty else { return }
        // The daily limit again, now: the review checked it when the list was prepared, and other sends may have gone since.
        if let block = batchLimitBlock(todo, unit: unit) { throw WalletError.blocked(block) }

        // Balances now, before asking for the key: what is left of the list has to fit, with fees, rent and the reserve.
        var needSOL = UInt128(info.keep), needToken: UInt128 = 0, amounts: UInt128 = 0
        for r in todo {
            let v = (try? Units.parse(r.amount, decimals: plan.decimals)) ?? 0
            amounts += v
            if mint == nil {
                needSOL += v + UInt128(info.feePlain)
            } else {
                needToken += v
                needSOL += UInt128(r.needsAccount == true ? info.feeWithAccount + info.rentPerAccount : info.feePlain)
            }
        }
        let lamports = try await node.lamports(of: from)
        guard UInt128(lamports) >= needSOL else {
            throw WalletError.insufficientFunds("Not enough SOL on \(chain.name) for what is left of this batch: it needs \(Units.format(needSOL, decimals: 9)) SOL with fees, rent and the \(SolanaBatch.sol(info.keep)) SOL that stays. Nothing was sent.")
        }
        if let mint {
            let mine = SolanaPublicKey.associatedTokenAccount(owner: from, mint: mint)
            let have = try await node.accountSummaries([mine]).first.flatMap { $0 }?.tokenAmount ?? 0
            guard have >= needToken else {
                throw WalletError.insufficientFunds("Not enough \(plan.symbol) for what is left of this batch. Nothing was sent.")
            }
        }

        let reason = "Send \(Units.format(amounts, decimals: plan.decimals)) \(plan.symbol) to \(todo.count) address\(todo.count == 1 ? "" : "es") on \(chain.name)"
        // One unlock for the run. The seed stays in a wiped buffer that is released when this call returns.
        let held = try await vault.withKey(w.id, kind: .solana, reason: reason) { seed in SecretBytes(seed) }
        let signer: @Sendable (SolanaTransaction) throws -> SolanaTransaction = { unsigned in
            try held.withBytes { (seed: [UInt8]) throws -> SolanaTransaction in
                var t = unsigned
                try t.sign(ed25519Seed: seed)
                return t
            }
        }
        var sender = SolanaBatchSender(node: node, sign: signer)
        if let pause { sender.pause = pause }
        // Balances are read again afterwards, whatever happened (not when a test handed in its own node).
        let live = given == nil
        do {
            try await sender.run(current, from: from, update: report)
        } catch {
            if live { Task { await refreshBalances(chains: [chain]) } }
            throw error
        }
        if live { Task { await refreshBalances(chains: [chain]) } }
    }
}
