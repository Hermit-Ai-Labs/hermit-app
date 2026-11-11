import XCTest
import CryptoKit
@testable import HermitWallet

/// A Solana node answered from memory: accounts as the test sets them, and transfers that confirm, fail, never land
/// or are refused, by the order they are submitted in. It also checks the one rule of a sequential sender: no transfer
/// is submitted while an earlier one is still unconfirmed.
final class FakeSolanaNode: SolanaBatchNode, @unchecked Sendable {
    /// `seen`: the node knows the transfer and never confirms it.
    enum Fate { case confirm, failOnChain, never, seen }

    private let lock = NSLock()
    var lamportsValue: UInt64 = 5_000_000_000
    var accounts: [String: SolanaAccountSummary] = [:]
    var height: UInt64 = 1_000
    var lastValid: UInt64 = 1_150
    var simulation: String?
    /// By submit attempt (0-based, over the node's whole life): the error that attempt gets instead of going out.
    var refuse: [Int: Error] = [:]
    /// An attempt that throws but goes out anyway (a timeout after the node took it).
    var lostAnswer: Set<Int> = []
    /// By submit attempt: what becomes of an accepted transfer. Default: it confirms.
    var fate: [Int: Fate] = [:]
    /// How many status polls answer "not yet" before the verdict shows.
    var pollsBeforeVerdict = 2

    private var attempts = 0
    private var verdicts: [String: (status: SolanaSignatureStatus?, waits: Int)] = [:]
    private var seen: Set<String> = []
    private var out: [SolanaTransaction] = []
    private var hashes = 0
    private var early = 0

    /// Every transfer that reached the network, in order.
    var accepted: [SolanaTransaction] { lock.withLock { out } }
    var submitAttempts: Int { lock.withLock { attempts } }
    /// Times a transfer was submitted while an earlier one had no confirmed answer yet. Must stay 0.
    var sentBeforeConfirmed: Int { lock.withLock { early } }
    var blockhashes: Int { lock.withLock { hashes } }

    /// Makes a signature confirmed (or failed) from now on, as if it landed after the sender gave up on it.
    func land(_ signature: String, _ status: SolanaSignatureStatus) { lock.withLock { verdicts[signature] = (status: status, waits: 0) } }

    func lamports(of account: SolanaPublicKey) async throws -> UInt64 { lock.withLock { lamportsValue } }
    func accountSummaries(_ keys: [SolanaPublicKey]) async throws -> [SolanaAccountSummary?] {
        let known = lock.withLock { accounts }
        return keys.map { known[$0.description] }
    }
    func rentExempt(bytes: Int) async throws -> UInt64 { bytes == 0 ? 890_880 : 2_039_280 }
    func priorityPrice(for accounts: [SolanaPublicKey]) async throws -> UInt64 { 10_000 }
    func dryRun(_ tx: SolanaTransaction) async throws -> String? { lock.withLock { simulation } }
    func blockhash() async throws -> SolanaBlockhash { nextBlockhash() }
    private func nextBlockhash() -> SolanaBlockhash {
        lock.lock()
        defer { lock.unlock() }
        hashes += 1
        return SolanaBlockhash(hash: [UInt8](repeating: UInt8(truncatingIfNeeded: hashes), count: 32), lastValidBlockHeight: lastValid)
    }
    func blockHeight() async throws -> UInt64 { lock.withLock { height } }

    func submit(_ tx: SolanaTransaction) async throws -> String {
        if let failure = take(tx) { throw failure }
        return tx.signature
    }

    /// One submit attempt: refused (the error comes back and nothing goes out), or taken, with or without an answer.
    private func take(_ tx: SolanaTransaction) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let n = attempts
        attempts += 1
        if !out.allSatisfy({ seen.contains($0.signature) }) { early += 1 }
        let lost = lostAnswer.contains(n)
        if let e = refuse[n], !lost { return e }
        out.append(tx)
        switch fate[n] ?? .confirm {
        case .confirm: verdicts[tx.signature] = (status: .confirmed, waits: pollsBeforeVerdict)
        case .failOnChain: verdicts[tx.signature] = (status: .failed("Failed on chain"), waits: pollsBeforeVerdict)
        case .never: verdicts[tx.signature] = (status: nil, waits: 0)
        case .seen: verdicts[tx.signature] = (status: .seen, waits: 0)
        }
        if lost {
            let e: Error = refuse[n] ?? URLError(.timedOut)
            return e
        }
        return nil
    }

    func status(of signature: String) async throws -> SolanaSignatureStatus? { verdict(signature) }
    private func verdict(_ signature: String) -> SolanaSignatureStatus? {
        lock.lock()
        defer { lock.unlock() }
        guard var v = verdicts[signature] else { return nil }
        if v.waits > 0 {
            v.waits -= 1
            verdicts[signature] = v
            return nil
        }
        if v.status != nil { seen.insert(signature) }
        return v.status
    }
}

/// Counts every unlock of the key store: one unlock is one Face ID / Touch ID.
final class CountingStore: SealedStore, @unchecked Sendable {
    private let inner = HermitWallet.MemoryStore()
    private let lock = NSLock()
    private var count = 0
    var opens: Int { lock.withLock { count } }
    var protection: KeyVault.Protection { inner.protection }
    func seal(_ secret: [UInt8], id: UUID) throws { try inner.seal(secret, id: id) }
    func open(id: UUID, reason: String) async throws -> SecretBytes {
        lock.withLock { count += 1 }
        return try await inner.open(id: id, reason: reason)
    }
    func remove(id: UUID) throws { try inner.remove(id: id) }
    func loadIndex() -> Data? { inner.loadIndex() }
    func saveIndex(_ data: Data) throws { try inner.saveIndex(data) }
}

/// The plan as the review sheet's store keeps it: every row update lands on its row.
@MainActor
final class PlanBox {
    var plan: BatchPlan
    var events: [String] = []
    /// The plan as it was saved at each event ("1 broadcast"): what the app would come back to if it stopped right there.
    var saved: [String: BatchPlan] = [:]
    /// Read at each event (how many transfers the node had been handed by then).
    var probe: (() -> Int)?
    var probed: [String: Int] = [:]
    init(_ plan: BatchPlan) { self.plan = plan }
    func apply(_ row: BatchRow) {
        if let i = plan.rows.firstIndex(where: { $0.line == row.line }) { plan.rows[i] = row }
    }
    func apply(_ row: BatchRow, _ event: SolanaBatchSender.Event) {
        let name = "\(row.line) \(event)"
        events.append(name)
        if let probe { probed[name] = probe() }
        apply(row)
        saved[name] = plan
    }
    var statuses: [BatchRow.Status] { plan.rows.map(\.status) }
}

/// Solana batch sends: the guards on the list, the review's arithmetic (fees, rent, totals, decimals), the spending
/// policy, and the sender that goes one by one, stops on a failure and retries the rest. No network, no real key.
@MainActor
final class SolanaBatchTests: XCTestCase {
    let seed = [UInt8](repeating: 200, count: 32)
    var from: SolanaPublicKey { key(200) }
    let usdcMint = SolanaPublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")!
    var usdc: SolanaBatch.Token { SolanaBatch.Token(mint: usdcMint.description, symbol: "USDC", decimals: 6) }
    let roomy = SolanaBatch.Limits(unitUSD: 1, dailyLeft: 500, dailyLimit: 500, agentCap: 100)
    let phrase = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"

    /// A real ed25519 public key (on the curve), one per number.
    func key(_ n: UInt8) -> SolanaPublicKey {
        let k = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data([UInt8](repeating: n, count: 32)))
        return SolanaPublicKey(bytes: [UInt8](k.publicKey.rawRepresentation))
    }
    func address(_ n: UInt8) -> String { key(n).description }

    func signer() -> @Sendable (SolanaTransaction) throws -> SolanaTransaction {
        let seed = self.seed
        return { unsigned in
            var t = unsigned
            try t.sign(ed25519Seed: seed)
            return t
        }
    }

    /// A reviewed plan for recipients 1…n, all existing wallets; `newAccounts` are the rows (1-based) without a token account.
    func plan(_ token: SolanaBatch.Token?, _ amounts: [String], newAccounts: Set<Int> = [], lamports: UInt64 = 5_000_000_000,
              tokenBalance: UInt128 = 1_000_000_000, limits: SolanaBatch.Limits? = nil, origin: ActionOrigin = .user) -> BatchPlan {
        var recipients: [(address: String, amount: String)] = []
        for (i, a) in amounts.enumerated() { recipients.append((address: address(UInt8(i + 1)), amount: a)) }
        let drafts = SolanaBatch.drafts(recipients, sender: from, mint: token?.mint, symbol: token?.symbol ?? "SOL", decimals: token?.decimals ?? 9)
        var facts = SolanaBatch.Facts(lamports: lamports, tokenBalance: tokenBalance, priorityPrice: 10_000)
        for (i, r) in recipients.enumerated() {
            facts.owners[r.address] = .wallet
            if token != nil { facts.tokenAccounts[r.address] = newAccounts.contains(i + 1) ? .missing : .ready }
        }
        return SolanaBatch.review(walletID: UUID(), chain: Chain.solana, token: token, drafts: drafts, facts: facts, limits: limits ?? roomy, origin: origin)
    }

    /// What a submitted transaction moves: the destination account of its last instruction and the amount in base units.
    func moved(_ tx: SolanaTransaction) -> (to: SolanaPublicKey, amount: UInt64) {
        let ix = tx.message.instructions.last!
        let token = ix.program == SolanaPublicKey.tokenProgram
        let bytes = Array(token ? ix.data[1..<9] : ix.data[4..<12])
        var amount: UInt64 = 0
        for (i, b) in bytes.enumerated() { amount |= UInt64(b) << UInt64(8 * i) }
        return (token ? ix.accounts[2].key : ix.accounts[1].key, amount)
    }

    func sender(_ node: FakeSolanaNode, maxPolls: Int = 40) -> SolanaBatchSender {
        SolanaBatchSender(node: node, sign: signer(), pause: { _ in }, pollEvery: .milliseconds(1), maxPolls: maxPolls)
    }

    func run(_ box: PlanBox, _ node: FakeSolanaNode, maxPolls: Int = 40) async throws {
        box.plan.rows = try await SolanaBatchSender.settle(box.plan.rows, node: node) { row, event in box.apply(row, event) }
        try await sender(node, maxPolls: maxPolls).run(box.plan, from: from) { row, event in box.apply(row, event) }
    }

    func message(_ error: Error) -> String { (error as? WalletError)?.errorDescription ?? "\(error)" }

    // MARK: Guards on the list

    func testListGuards() {
        let a = address(1), b = address(2)
        let rows: [(address: String, amount: String)] = [
            (a, "12.5"), (a, "3"), (from.description, "1"), ("not-an-address", "1"),
            ("0x52908400098527886E0F7030069857D2E4169EE7", "1"), ("alice.sol", "1"), (b, "0"), (address(3), "-5"),
            (address(4), "1.1234567"), (address(5), "25,5"), (address(6), ""), (usdcMint.description, "1"), (address(7), "1,000"),
            ("  \(address(8))  ", " 0.000001 "),
        ]
        let d = SolanaBatch.drafts(rows, sender: from, mint: usdcMint.description, symbol: "USDC", decimals: 6)
        XCTAssertEqual(d.map(\.problem), [
            nil, "Same address as row 1", "That's this wallet", "Not a Solana address", "That's an EVM address, not a Solana one",
            "Names aren't looked up in a batch; use the address", "Amount 0 isn't valid for USDC", "Amount -5 isn't valid for USDC",
            "Amount 1.1234567 isn't valid for USDC", "Unclear amount. Write it with a dot, like 25.5", "No amount",
            "That's the token itself, not a wallet", nil, nil,
        ])
        // Exactly what was given, in base units: never rounded, a thousands comma read as one.
        XCTAssertEqual(d[0].value, 12_500_000)
        XCTAssertEqual(d[0].amountText, "12.5")
        XCTAssertEqual(d[12].value, 1_000_000_000)
        XCTAssertEqual(d[13].value, 1)
        XCTAssertEqual(d[13].address, address(8), "spaces around an address don't change it")
        XCTAssertEqual(d.map(\.line), Array(1...14))
        // A problem row carries no amount to send.
        XCTAssertTrue(d.filter { $0.problem != nil }.allSatisfy { $0.value == 0 })
    }

    func testPictureAndWhitelistRules() {
        let a = address(1), b = address(2)
        // From a picture a Solana address has nothing to catch a misread character: only known ones pass.
        let book = SolanaBatch.Book(payments: { $0 == a ? 2 : 0 })
        let d = SolanaBatch.drafts([(a, "1"), (b, "1")], sender: from, mint: nil, symbol: "SOL", decimals: 9, fromPicture: true, book: book)
        XCTAssertNil(d[0].problem)
        XCTAssertEqual(d[1].problem, "Read from a picture, and Solana addresses have no checksum. Paste this address instead.")
        // Whitelist only stops a row on the review, with its reason.
        let strict = SolanaBatch.Book(whitelistBlock: { $0 == b ? "Whitelist only is on and this address isn't saved." : nil })
        let w = SolanaBatch.drafts([(a, "1"), (b, "1")], sender: from, mint: nil, symbol: "SOL", decimals: 9, book: strict)
        XCTAssertEqual(w.map(\.problem), [nil, "Whitelist only is on and this address isn't saved."])
    }

    /// What sits at an address decides whether money can go there: a token account or a program never gets it.
    func testRecipientAccountGuards() {
        let recipients: [(address: String, amount: String)] = (1...6).map { (address(UInt8($0)), "1") }
        // An associated token account is an address no key signs for (off the curve).
        let offCurve = SolanaPublicKey.associatedTokenAccount(owner: key(9), mint: usdcMint).description
        // The same kind of address with SOL on it: a program's vault or a multisig. System-owned, and still no key signs for it.
        let vault = SolanaPublicKey.associatedTokenAccount(owner: key(10), mint: usdcMint).description
        let all = recipients + [(address: offCurve, amount: "1"), (address: vault, amount: "1")]
        let drafts = SolanaBatch.drafts(all, sender: from, mint: usdcMint.description, symbol: "USDC", decimals: 6)
        var facts = SolanaBatch.Facts(lamports: 1_000_000_000, tokenBalance: 100_000_000)
        facts.owners = [address(1): .wallet, address(2): .missing, address(3): .tokenAccount, address(4): .program, address(5): .wallet,
                        offCurve: .missing, vault: .wallet]
        facts.tokenAccounts = [address(1): .ready, address(2): .missing, address(5): .frozen, offCurve: .missing, vault: .ready]
        let p = SolanaBatch.review(walletID: UUID(), chain: Chain.solana, token: usdc, drafts: drafts, facts: facts, limits: roomy, origin: .user)
        XCTAssertEqual(p.rows.map(\.problem), [
            nil, nil, "That's a token account, not a wallet. Use its owner's wallet address", "That's a program's account, not a wallet",
            "Their USDC account is frozen", "Couldn't check this address. Try again", "Not a wallet address: no key can sign for it",
            "A program controls this address (a vault or multisig), not a key. Send to it on its own from Wallets",
        ])
        XCTAssertEqual(p.rows.map(\.status), [.ready, .ready, .invalid, .invalid, .invalid, .invalid, .invalid, .invalid])
        // A wallet that doesn't exist yet can still be paid a token: its account is created, and that row carries the rent.
        XCTAssertEqual(p.rows[0].needsAccount, false)
        XCTAssertEqual(p.rows[1].needsAccount, true)
        XCTAssertNil(p.rows[2].needsAccount)
        XCTAssertEqual(p.total, "2")
        XCTAssertEqual(p.solana?.newAccounts, 1)
        XCTAssertTrue(p.warnings.contains("6 rows left out (listed below with the reason)."))
        XCTAssertFalse(p.checks.contains("Every address is a wallet, no duplicates"))

        // The node's answers, read: a wallet is System-owned, anything a token program owns is not a wallet.
        XCTAssertEqual(SolanaBatch.owner(nil), .missing)
        XCTAssertEqual(SolanaBatch.owner(SolanaAccountSummary(owner: SolanaPrograms.system, lamports: 1)), .wallet)
        XCTAssertEqual(SolanaBatch.owner(SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 1)), .tokenAccount)
        XCTAssertEqual(SolanaBatch.owner(SolanaAccountSummary(owner: SolanaPrograms.token2022, lamports: 1)), .tokenAccount)
        XCTAssertEqual(SolanaBatch.owner(SolanaAccountSummary(owner: SolanaPrograms.system, lamports: 1, executable: true)), .program)
        XCTAssertEqual(SolanaBatch.owner(SolanaAccountSummary(owner: "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4", lamports: 1)), .program)
        let mine = address(1), mint = usdcMint.description
        func account(mint m: String? = nil, owner o: String? = nil, state: String = "initialized") -> SolanaAccountSummary {
            SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 2_039_280, parsedType: "account", tokenMint: m ?? mint, tokenOwner: o ?? mine,
                                 tokenAmount: 5, tokenState: state)
        }
        XCTAssertEqual(SolanaBatch.tokenAccount(nil, mint: mint, owner: mine), .missing)
        XCTAssertEqual(SolanaBatch.tokenAccount(account(), mint: mint, owner: mine), .ready)
        XCTAssertEqual(SolanaBatch.tokenAccount(account(state: "frozen"), mint: mint, owner: mine), .frozen)
        XCTAssertEqual(SolanaBatch.tokenAccount(account(owner: address(2)), mint: mint, owner: mine), .unusable, "someone else's account")
        XCTAssertEqual(SolanaBatch.tokenAccount(account(mint: address(3)), mint: mint, owner: mine), .unusable, "another token")
        XCTAssertEqual(SolanaBatch.tokenAccount(SolanaAccountSummary(owner: SolanaPrograms.system, lamports: 5), mint: mint, owner: mine), .unusable)
    }

    func testAccountAnswersAreReadOrRefused() throws {
        func json(_ s: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
        XCTAssertNil(try SolanaAccountSummary.parse(.null), "no account there")
        let wallet = try XCTUnwrap(try SolanaAccountSummary.parse(try json(#"{"lamports":1500000,"owner":"11111111111111111111111111111111","executable":false,"data":["","base64"]}"#)))
        XCTAssertEqual(wallet.owner, SolanaPrograms.system)
        XCTAssertEqual(wallet.lamports, 1_500_000)
        XCTAssertNil(wallet.parsedType)
        let token = try XCTUnwrap(try SolanaAccountSummary.parse(try json("""
        {"lamports":2039280,"owner":"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","executable":false,
         "data":{"program":"spl-token","parsed":{"type":"account","info":{"mint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
         "owner":"HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk","state":"initialized","tokenAmount":{"amount":"37750000","decimals":6}}}}}
        """)))
        XCTAssertEqual(token.parsedType, "account")
        XCTAssertEqual(token.tokenAmount, 37_750_000)
        XCTAssertEqual(token.tokenOwner, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        let mint = try XCTUnwrap(try SolanaAccountSummary.parse(try json(#"{"lamports":1,"owner":"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","data":{"parsed":{"type":"mint","info":{"decimals":6}}}}"#)))
        XCTAssertEqual(mint.mintDecimals, 6)
        // An answer that can't be read is an error, never "nothing there" (that would price an account creation).
        XCTAssertThrowsError(try SolanaAccountSummary.parse(try json(#"{"owner":"x"}"#)))
    }

    // MARK: The review's arithmetic

    func testFees() {
        XCTAssertEqual(SolanaBatch.fee(units: 30_000, price: 10_000), 5_300)
        XCTAssertEqual(SolanaBatch.fee(units: 100_000, price: 10_000), 6_000)
        XCTAssertEqual(SolanaBatch.fee(units: 1_500, price: 1_000), 5_002, "the priority part is rounded up")
        XCTAssertEqual(SolanaBatch.fee(units: 1_500, price: 0), 5_000)
        XCTAssertEqual(SolanaBatch.sol(2_039_280), "0.00203928")
        XCTAssertEqual(SolanaBatch.sol(890_880), "0.00089088")
        XCTAssertEqual(SolanaBatch.maxRecipients, 50)
    }

    /// USDC to three wallets, one of them without a USDC account: its rent is on its row and in the total.
    func testTokenReviewMath() {
        let p = plan(usdc, ["12.5", "25", "0.25"], newAccounts: [3], lamports: 2_946_760, tokenBalance: 37_750_000)
        XCTAssertEqual(p.total, "37.75")
        XCTAssertEqual(p.symbol, "USDC")
        XCTAssertEqual(p.decimals, 6)
        XCTAssertEqual(p.chainID, "solana")
        XCTAssertEqual(p.tokenAddress, usdcMint.description)
        XCTAssertEqual(p.rows.map(\.needsAccount), [false, false, true])
        let s = try! XCTUnwrap(p.solana)
        XCTAssertEqual(s.feePlain, 5_300)
        XCTAssertEqual(s.feeWithAccount, 6_000)
        XCTAssertEqual(s.feeTotal, 16_600, "two plain transfers and one that opens an account")
        XCTAssertEqual(s.rentPerAccount, 2_039_280)
        XCTAssertEqual(s.rentTotal, 2_039_280)
        XCTAssertEqual(s.newAccounts, 1)
        XCTAssertEqual(s.priorityPrice, 10_000)
        XCTAssertEqual(p.feeText, "0.0000166 SOL")
        XCTAssertEqual(s.rentEachText, "0.00203928")
        XCTAssertEqual(p.solanaTotalText, "37.75 USDC + 0.00205588 SOL")
        // Exactly enough: the tokens, and SOL for fees, rent and the 0.00089088 SOL that has to stay.
        XCTAssertEqual(p.blocks, [])
        XCTAssertTrue(p.canSend)
        XCTAssertTrue(p.checks.contains("Balance covers the total"))
        XCTAssertTrue(p.checks.contains("SOL covers 3 network fees and rent for 1 new USDC account"))
        XCTAssertTrue(p.checks.contains("Within daily limit ($462.25 left today)"))
        XCTAssertTrue(p.checks.contains("Signed on this device with one approval for all 3"))
        XCTAssertTrue(p.warnings.contains("1 recipient has no USDC account yet. Opening one costs you 0.00203928 SOL each, once."))
        XCTAssertEqual(p.unitUSD, "1")

        // One lamport short, or one base unit of the token short: caught on the review.
        let noSOL = plan(usdc, ["12.5", "25", "0.25"], newAccounts: [3], lamports: 2_946_759, tokenBalance: 37_750_000)
        XCTAssertEqual(noSOL.blocks, ["Not enough SOL on Solana: 3 network fees and rent for 1 new USDC account come to 0.00205588 SOL, and 0.00089088 SOL has to stay in the wallet. It has 0.002946759 SOL."])
        XCTAssertFalse(noSOL.canSend)
        let noToken = plan(usdc, ["12.5", "25", "0.25"], newAccounts: [3], lamports: 2_946_760, tokenBalance: 37_749_999)
        XCTAssertEqual(noToken.blocks, ["Not enough USDC: the list needs 37.75, this wallet has 37.749999."])
        // Without new accounts there is no rent at all.
        let plain = plan(usdc, ["1", "2"])
        XCTAssertEqual(plain.solana?.rentTotal, 0)
        XCTAssertEqual(plain.solanaTotalText, "3 USDC + 0.0000106 SOL")
        XCTAssertFalse(plain.warnings.contains { $0.contains("account yet") })
    }

    func testSolReviewMath() {
        // Fees at this price: 5,000 for the signature and 15 of priority (1,500 units at 10,000 micro-lamports).
        let p = plan(nil, ["0.5", "0.25"], lamports: 750_900_910)
        XCTAssertEqual(p.symbol, "SOL")
        XCTAssertEqual(p.decimals, 9)
        XCTAssertNil(p.tokenAddress)
        XCTAssertEqual(p.total, "0.75")
        XCTAssertEqual(p.solana?.feePlain, 5_015)
        XCTAssertEqual(p.solana?.feeTotal, 10_030)
        XCTAssertEqual(p.solana?.rentTotal, 0)
        XCTAssertEqual(p.rows.map(\.needsAccount), [nil, nil], "no token accounts for SOL")
        XCTAssertEqual(p.solanaTotalText, "0.75001003 SOL")
        XCTAssertEqual(p.blocks, [], "750,000,000 + 10,030 in fees + 890,880 that stays")
        let short = plan(nil, ["0.5", "0.25"], lamports: 750_900_909)
        XCTAssertEqual(short.blocks, ["Not enough SOL: the list and its 2 network fees come to 0.75001003 SOL, and 0.00089088 SOL has to stay in the wallet. It has 0.750900909 SOL."])

        // SOL to an address that doesn't exist yet has to cover that account's own minimum.
        let fresh = address(1)
        let drafts = SolanaBatch.drafts([(fresh, "0.0005"), (address(2), "0.00089088")], sender: from, mint: nil, symbol: "SOL", decimals: 9)
        var facts = SolanaBatch.Facts(lamports: 1_000_000_000)
        facts.owners = [fresh: .missing, address(2): .missing]
        let r = SolanaBatch.review(walletID: UUID(), chain: Chain.solana, token: nil, drafts: drafts, facts: facts, limits: roomy, origin: .user)
        XCTAssertEqual(r.rows.map(\.problem), ["A new address needs at least 0.00089088 SOL to open", nil])
    }

    /// Amounts are read with the mint's own decimals, exactly.
    func testDecimals() {
        let nine = SolanaBatch.Token(mint: address(40), symbol: "NINE", decimals: 9, usd: 2)
        let d = SolanaBatch.drafts([(address(1), "0.000000001"), (address(2), "0.0000000001"), (address(3), "18446744073.709551615"),
                                    (address(4), "18446744073.709551616")], sender: from, mint: nine.mint, symbol: "NINE", decimals: 9)
        XCTAssertEqual(d.map(\.value), [1, 0, UInt64.max, 0])
        XCTAssertEqual(d[1].problem, "Amount 0.0000000001 isn't valid for NINE", "more decimals than the token has is refused, not cut")
        XCTAssertEqual(d[3].problem, "Amount 18446744073.709551616 isn't valid for NINE", "more than a transfer can carry")
        let zero = SolanaBatch.drafts([(address(1), "3"), (address(2), "1.5")], sender: from, mint: address(41), symbol: "WHOLE", decimals: 0)
        XCTAssertEqual(zero.map(\.value), [3, 0])
        // The transfer says the same decimals, so the chain checks them too.
        let ixs = SolanaBatch.instructions(from: from, to: key(1), amount: 1, mint: SolanaPublicKey(nine.mint), decimals: 9, createAccount: false, price: 1)
        XCTAssertEqual(ixs.last?.data, [12, 1, 0, 0, 0, 0, 0, 0, 0, 9])
    }

    // MARK: Spending policy

    func testPolicyOnTheBatchTotal() {
        // The whole batch is one move against the daily limit.
        let over = plan(usdc, ["300", "200.01"])
        XCTAssertEqual(over.blocks, ["Over your daily limit: $500 of $500 left today."])
        XCTAssertTrue(plan(usdc, ["300", "200"]).blocks.isEmpty)
        // The assistant's per-move cap is on the total too, and only when it prepared the batch.
        let agent = plan(usdc, ["60", "40.5"], origin: .agent)
        XCTAssertEqual(agent.blocks, ["The assistant can prepare up to $100 per move. Attach the list and ask again, or split it."])
        XCTAssertTrue(plan(usdc, ["60", "40"], origin: .agent).checks.contains("Under the assistant's $100 per-move cap"))
        XCTAssertTrue(plan(usdc, ["60", "40.5"], origin: .user).blocks.isEmpty)
        // No price: the assistant can't, and the user's own batch can't be checked against the limit either.
        let unpriced = SolanaBatch.Limits(unitUSD: nil, dailyLeft: 500, dailyLimit: 500, agentCap: 100)
        XCTAssertEqual(plan(usdc, ["1"], limits: unpriced, origin: .agent).blocks, ["The assistant can't send tokens without a price. Send USDC from Wallets yourself."])
        XCTAssertEqual(plan(usdc, ["1"], limits: unpriced).blocks.count, 1)
        // A priced token counts at its price: 3 SOL at $200 is $600.
        let sol = SolanaBatch.Limits(unitUSD: 200, dailyLeft: 500, dailyLimit: 500, agentCap: 100)
        XCTAssertEqual(plan(nil, ["1", "2"], limits: sol).blocks, ["Over your daily limit: $500 of $500 left today."])
        XCTAssertEqual(plan(nil, ["1", "2"], limits: sol).unitUSD, "200")
        // An unverified token says so on the review, with its mint.
        let odd = SolanaBatch.Token(mint: address(50), symbol: "ODD", decimals: 6, usd: 1, verified: false)
        XCTAssertTrue(plan(odd, ["1"]).warnings.contains { $0.contains("isn't on Jupiter's verified list") && $0.contains(address(50)) })
    }

    // MARK: One row's transaction

    func testInstructions() {
        let to = key(1)
        // SOL: compute budget and one System transfer.
        let sol = SolanaBatch.instructions(from: from, to: to, amount: 1_500, mint: nil, decimals: 9, createAccount: false, price: 7)
        XCTAssertEqual(sol.count, 3)
        XCTAssertEqual(sol[2], .transfer(from: from, to: to, lamports: 1_500))
        XCTAssertTrue(SolanaBatch.says(sol, from: from, to: to, amount: 1_500, mint: nil, decimals: 9))
        XCTAssertFalse(SolanaBatch.says(sol, from: from, to: to, amount: 1_501, mint: nil, decimals: 9))
        XCTAssertFalse(SolanaBatch.says(sol, from: from, to: key(2), amount: 1_500, mint: nil, decimals: 9))
        // A token: transferChecked between the two associated accounts, with the mint's decimals.
        let plain = SolanaBatch.instructions(from: from, to: to, amount: 2_500_000, mint: usdcMint, decimals: 6, createAccount: false, price: 7)
        XCTAssertEqual(plain.count, 3)
        let source = SolanaPublicKey.associatedTokenAccount(owner: from, mint: usdcMint), dest = SolanaPublicKey.associatedTokenAccount(owner: to, mint: usdcMint)
        XCTAssertEqual(plain[2], .transferChecked(source: source, mint: usdcMint, destination: dest, owner: from, amount: 2_500_000, decimals: 6))
        XCTAssertFalse(plain.contains { $0.program == SolanaPublicKey.associatedTokenProgram }, "no account is opened unless the review priced it")
        // With a new account: created idempotently, in the same transaction, before the transfer.
        let new = SolanaBatch.instructions(from: from, to: to, amount: 2_500_000, mint: usdcMint, decimals: 6, createAccount: true, price: 7)
        XCTAssertEqual(new.count, 4)
        XCTAssertEqual(new[2], .createAssociatedTokenAccountIdempotent(payer: from, owner: to, mint: usdcMint))
        XCTAssertEqual(new[2].data, [1], "the idempotent create")
        XCTAssertEqual(new[3], plain[2])
        XCTAssertEqual(new[0], .setComputeUnitLimit(100_000))
        XCTAssertEqual(plain[0], .setComputeUnitLimit(30_000))
        XCTAssertEqual(new[1], .setComputeUnitPrice(7))
        XCTAssertTrue(SolanaBatch.says(new, from: from, to: to, amount: 2_500_000, mint: usdcMint, decimals: 6))
        XCTAssertFalse(SolanaBatch.says(new, from: from, to: to, amount: 2_500_000, mint: usdcMint, decimals: 9))
        // A second transfer in the same transaction is never what a row says.
        XCTAssertFalse(SolanaBatch.says(plain + [plain[2]], from: from, to: to, amount: 2_500_000, mint: usdcMint, decimals: 6))
    }

    func testLinksAndSavedPlans() throws {
        let p = plan(usdc, ["1", "2"], newAccounts: [2])
        XCTAssertEqual(p.transactionURL("5abc")?.absoluteString, "https://solscan.io/tx/5abc")
        // A plan survives being saved and read back with everything the review showed.
        let back = try JSONDecoder().decode(BatchPlan.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.rows, p.rows)
        XCTAssertEqual(back.solana, p.solana)
        XCTAssertEqual(back.rows.map(\.needsAccount), [false, true])
        XCTAssertEqual(back.solanaTotalText, p.solanaTotalText)
        // A batch saved before Solana batches existed still reads (no Solana fields), and links to its own explorer.
        let old = """
        {"id":"x","walletID":"\(UUID().uuidString)","chainID":"base","symbol":"USDC","tokenAddress":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
         "decimals":6,"rows":[{"line":1,"input":"a","address":"0x1111111111111111111111111111111111111111","amount":"1","status":"ready"}],
         "total":"1","feeText":"0.000006 ETH","gasLimit":65000,"checks":[],"warnings":[],"blocks":[],"origin":"user","created":0}
        """
        let evm = try JSONDecoder().decode(BatchPlan.self, from: Data(old.utf8))
        XCTAssertNil(evm.solana)
        XCTAssertNil(evm.solanaTotalText)
        XCTAssertNil(evm.rows[0].needsAccount)
        XCTAssertEqual(evm.transactionURL("0xabc")?.absoluteString, "https://basescan.org/tx/0xabc")
    }

    // MARK: The sender

    /// Every row goes out once, in list order, each with a fresh blockhash, and never before the one before it confirmed.
    func testSendsOneByOne() async throws {
        let node = FakeSolanaNode()
        let box = PlanBox(plan(nil, ["0.1", "0.2", "0.3"]))
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .confirmed])
        XCTAssertTrue(box.plan.done)
        XCTAssertEqual(node.accepted.count, 3)
        XCTAssertEqual(node.sentBeforeConfirmed, 0, "each transfer waits for the one before it")
        XCTAssertEqual(node.blockhashes, 3, "a fresh blockhash per transfer")
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [100_000_000, 200_000_000, 300_000_000])
        XCTAssertEqual(node.accepted.map { moved($0).to }, [key(1), key(2), key(3)])
        XCTAssertTrue(node.accepted.allSatisfy { $0.verifySignature() && $0.message.accountKeys[0] == from })
        // Each row's link is its own transaction.
        XCTAssertEqual(box.plan.rows.map(\.hash), node.accepted.map { Optional($0.signature) })
        XCTAssertEqual(box.events, ["1 broadcast", "1 confirmed", "2 broadcast", "2 confirmed", "3 broadcast", "3 confirmed"])
        // The priority price the review showed is the one that is signed.
        XCTAssertTrue(node.accepted.allSatisfy { $0.message.instructions[1] == .setComputeUnitPrice(10_000) })
    }

    /// A refused transfer stops the run: what went, what failed (with the reason) and what never started are all told
    /// apart, and Retry sends only the rest.
    func testStopsOnFailureAndRetriesTheRest() async throws {
        let node = FakeSolanaNode()
        node.refuse[2] = WalletError.rpc(code: -32002, message: "Transaction simulation failed: Error processing Instruction 2: custom program error: 0x1")
        let box = PlanBox(plan(usdc, ["1", "2", "3", "4", "5"], newAccounts: [4]))
        do {
            try await run(box, node)
            XCTFail("row 3 was refused")
        } catch {
            XCTAssertEqual(message(error), "Row 3 failed: Not enough balance for this transfer. 2 sent before it, 2 not started. Retry sends the rest after a new approval.")
        }
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .failed, .ready, .ready])
        XCTAssertEqual(box.plan.rows[2].error, "Not enough balance for this transfer")
        XCTAssertNil(box.plan.rows[2].hash, "it never went out")
        XCTAssertEqual(node.accepted.count, 2)
        XCTAssertEqual(node.submitAttempts, 3, "nothing after the failed row was tried")
        XCTAssertEqual(box.plan.remaining.map(\.line), [3, 4, 5])
        XCTAssertFalse(box.plan.done)

        // Retry: rows 3, 4 and 5 only. Rows 1 and 2 are never sent a second time.
        node.refuse = [:]
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .confirmed, .confirmed, .confirmed])
        XCTAssertEqual(node.accepted.count, 5)
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000])
        XCTAssertEqual(node.sentBeforeConfirmed, 0)
        // Only the row the review priced with rent opens an account.
        let opens = node.accepted.map { tx in tx.message.instructions.contains { $0.program == SolanaPublicKey.associatedTokenProgram } }
        XCTAssertEqual(opens, [false, false, false, true, false])
        let dest = SolanaPublicKey.associatedTokenAccount(owner: key(4), mint: usdcMint)
        XCTAssertEqual(moved(node.accepted[3]).to, dest)
    }

    func testFailedOnChainStops() async throws {
        let node = FakeSolanaNode()
        node.fate[1] = .failOnChain
        let box = PlanBox(plan(nil, ["0.1", "0.2", "0.3"]))
        do { try await run(box, node); XCTFail("row 2 failed on chain") } catch {
            XCTAssertTrue(message(error).hasPrefix("Row 2 failed: Failed on chain. 1 sent before it, 1 not started."), message(error))
        }
        XCTAssertEqual(box.statuses, [.confirmed, .failed, .ready])
        XCTAssertNotNil(box.plan.rows[1].hash, "the failed transaction can still be looked at")
        XCTAssertEqual(node.accepted.count, 2)
        // It moved nothing, so Retry sends it again, then the rest.
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .confirmed])
        XCTAssertEqual(node.accepted.count, 4)
    }

    /// A transfer that never shows up is only called not sent once the chain is past its last valid block.
    func testExpiredTransferStopsAndCanGoAgain() async throws {
        let node = FakeSolanaNode()
        node.fate[0] = .never
        node.height = node.lastValid + SolanaBatch.expiryMargin + 1
        let box = PlanBox(plan(nil, ["0.1", "0.2"]))
        do { try await run(box, node); XCTFail("row 1 expired") } catch {
            XCTAssertTrue(message(error).hasPrefix("Row 1 failed: It expired before reaching the chain. Nothing moved. None sent before it, 1 not started."), message(error))
        }
        XCTAssertEqual(box.statuses, [.failed, .ready])
        XCTAssertNil(box.plan.rows[0].hash)
        XCTAssertEqual(node.submitAttempts, 1)
        node.fate = [:]
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed])
    }

    /// The dangerous case: a transfer went out and nobody can say yet whether it landed. It is never sent again while
    /// it still could land, and nothing after it is sent either.
    func testUnconfirmedTransferIsNeverSentTwice() async throws {
        let node = FakeSolanaNode()
        // Row 2: the node took it, but the answer was lost, and no verdict shows.
        node.lostAnswer = [1]
        node.fate[1] = .never
        let box = PlanBox(plan(nil, ["0.1", "0.2", "0.3"]))
        do { try await run(box, node, maxPolls: 6); XCTFail("row 2 is unconfirmed") } catch {
            XCTAssertTrue(message(error).contains("Row 2 was sent but isn't confirmed yet"), message(error))
            XCTAssertTrue(message(error).contains("1 sent before it, 1 not started"), message(error))
        }
        XCTAssertEqual(box.statuses, [.confirmed, .sent, .ready])
        XCTAssertEqual(box.plan.rows[1].error, "Not confirmed yet")
        let pending = try XCTUnwrap(box.plan.rows[1].hash)
        XCTAssertEqual(box.plan.rows[1].lastValid, node.lastValid)
        XCTAssertEqual(box.events.last, "2 unconfirmed")
        XCTAssertEqual(node.accepted.count, 2)

        // Still inside its window: trying again sends nothing at all.
        do { try await run(box, node); XCTFail("still pending") } catch {
            XCTAssertEqual(message(error), "Row 2 is still confirming, so nothing new was sent. Try again in a minute.")
        }
        XCTAssertEqual(node.submitAttempts, 2)
        XCTAssertEqual(box.statuses, [.confirmed, .sent, .ready])

        // It landed after all: it is marked sent, and only row 3 goes out.
        node.land(pending, .confirmed)
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .confirmed])
        XCTAssertEqual(node.accepted.count, 3, "row 2 was never sent a second time")
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [100_000_000, 200_000_000, 300_000_000])
        XCTAssertTrue(box.events.contains("2 settledConfirmed"))
    }

    func testUnconfirmedTransferThatExpiredGoesAgain() async throws {
        let node = FakeSolanaNode()
        node.fate[0] = .never
        let box = PlanBox(plan(nil, ["0.1", "0.2"]))
        do { try await run(box, node, maxPolls: 6); XCTFail("row 1 is unconfirmed") } catch {}
        XCTAssertEqual(box.statuses, [.sent, .ready])
        // Just past its last valid block isn't enough; past the margin, it can't land anymore.
        node.height = node.lastValid + SolanaBatch.expiryMargin
        do { try await run(box, node); XCTFail("still inside the margin") } catch {}
        XCTAssertEqual(node.submitAttempts, 1)
        node.height = node.lastValid + SolanaBatch.expiryMargin + 1
        node.fate = [:]
        try await run(box, node)
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed])
        XCTAssertEqual(node.accepted.count, 3, "the expired one, then both rows")
        XCTAssertTrue(box.events.contains("1 settledFailed"))
    }

    /// A row is reported as sent, with its transaction id, before the transfer is handed to the network. So a run that
    /// is cut short (the app closed mid-run) leaves a saved batch that looks the transfer up instead of paying it again.
    func testInterruptedRunNeverPaysTwice() async throws {
        let node = FakeSolanaNode()
        node.refuse[1] = WalletError.rpc(code: -32002, message: "Transaction simulation failed: Blockhash not found")
        let box = PlanBox(plan(nil, ["0.1", "0.2"]))
        box.probe = { node.submitAttempts }
        do { try await run(box, node); XCTFail("row 2 was refused") } catch {}
        XCTAssertEqual(box.probed["1 broadcast"], 0, "row 1 was on record before the node got it")
        XCTAssertEqual(box.probed["2 broadcast"], 1)
        XCTAssertEqual(box.statuses, [.confirmed, .failed])
        XCTAssertNil(box.plan.rows[1].hash, "a refused transfer keeps no id: it never went out")
        XCTAssertEqual(node.accepted.count, 1)

        // The app stopped right after row 1 went out: this is the batch it comes back to.
        let back = PlanBox(try XCTUnwrap(box.saved["1 broadcast"]))
        XCTAssertEqual(back.statuses, [.sent, .ready])
        XCTAssertEqual(back.plan.rows[0].hash, node.accepted[0].signature)
        XCTAssertEqual(back.plan.rows[0].lastValid, node.lastValid)
        XCTAssertEqual(back.plan.remaining.map(\.line), [2], "row 1 is not among the rows to send")
        node.refuse = [:]
        try await run(back, node)
        XCTAssertEqual(back.statuses, [.confirmed, .confirmed])
        XCTAssertEqual(node.accepted.count, 2, "row 1 was looked up, never sent a second time")
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [100_000_000, 200_000_000])
        XCTAssertEqual(back.events.first, "1 settledConfirmed")
    }

    /// A transfer the node knows but hasn't confirmed can still land: it is never called expired, whatever the height.
    func testSeenButUnconfirmedIsNeverSentAgain() async throws {
        let node = FakeSolanaNode()
        node.fate[0] = .never
        let box = PlanBox(plan(nil, ["0.1", "0.2"]))
        do { try await run(box, node, maxPolls: 6); XCTFail("row 1 is unconfirmed") } catch {}
        XCTAssertEqual(box.statuses, [.sent, .ready])
        let pending = try XCTUnwrap(box.plan.rows[0].hash)
        node.land(pending, .seen)
        node.height = node.lastValid + SolanaBatch.expiryMargin + 100
        do { try await run(box, node); XCTFail("still pending") } catch {
            XCTAssertEqual(message(error), "Row 1 is still confirming, so nothing new was sent. Try again in a minute.")
        }
        XCTAssertEqual(node.submitAttempts, 1)
        XCTAssertEqual(box.statuses, [.sent, .ready])
        // The same while a run is still waiting for it: past the height and only "seen" is not expired.
        let live = FakeSolanaNode()
        live.height = live.lastValid + SolanaBatch.expiryMargin + 100
        live.fate[0] = .seen
        let other = PlanBox(plan(nil, ["0.1", "0.2"]))
        do { try await run(other, live, maxPolls: 12); XCTFail("row 1 is unconfirmed") } catch {
            XCTAssertTrue(message(error).contains("Row 1 was sent but isn't confirmed yet"), message(error))
        }
        XCTAssertEqual(other.statuses, [.sent, .ready], "not failed, not expired")
        XCTAssertNotNil(other.plan.rows[0].hash)
        XCTAssertEqual(live.submitAttempts, 1)
    }

    /// A signature that isn't this wallet's is never broadcast.
    func testWrongKeyNeverBroadcasts() async throws {
        let node = FakeSolanaNode()
        let box = PlanBox(plan(nil, ["0.1"]))
        let other = SolanaBatchSender(node: node, sign: { unsigned in
            var t = unsigned
            try t.sign(ed25519Seed: [UInt8](repeating: 9, count: 32))
            return t
        }, pause: { _ in })
        do { try await other.run(box.plan, from: from) { row, event in box.apply(row, event) }; XCTFail("signed with another key") } catch {
            XCTAssertTrue(message(error).contains("Row 1 failed: It couldn't be signed"), message(error))
        }
        XCTAssertEqual(node.submitAttempts, 0)
        XCTAssertEqual(box.statuses, [.failed])
    }

    // MARK: Through the wallet

    func service(_ store: SealedStore) -> WalletService {
        let d = UserDefaults(suiteName: "hermit.wallet.tests.\(UUID())")!
        return WalletService(vault: KeyVault(store: store), addressBook: AddressBook(defaults: d), spendLimit: SpendLimit(defaults: d),
                             sendLog: SendLog(defaults: d))
    }

    /// The chain as the fake node tells it: a USDC mint, the sender's USDC, and four wallets, the third without a USDC account.
    func chain(for me: SolanaPublicKey, balance: UInt128 = 100_000_000) -> FakeSolanaNode {
        let node = FakeSolanaNode()
        let mint = usdcMint.description
        node.lamportsValue = 1_000_000_000
        node.accounts[mint] = SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 1, parsedType: "mint", mintDecimals: 6)
        func tokenAccount(of owner: SolanaPublicKey, amount: UInt128) {
            let a = SolanaPublicKey.associatedTokenAccount(owner: owner, mint: usdcMint)
            node.accounts[a.description] = SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 2_039_280, parsedType: "account", tokenMint: mint,
                                                                tokenOwner: owner.description, tokenAmount: amount, tokenState: "initialized")
        }
        tokenAccount(of: me, amount: balance)
        for n in 1...4 {
            node.accounts[address(UInt8(n))] = SolanaAccountSummary(owner: SolanaPrograms.system, lamports: 5_000_000)
            if n != 3 { tokenAccount(of: key(UInt8(n)), amount: 0) }
        }
        return node
    }

    /// A list on Solana goes to the Solana batch: reviewed with no unlock, sent with exactly one, and a Retry after a
    /// failure asks for the key again.
    func testOneApprovalForTheListAndAnotherForRetry() async throws {
        let store = CountingStore()
        let svc = service(store)
        let w = try svc.importWallet(phrase: phrase, name: "T")
        let me = try XCTUnwrap(SolanaPublicKey(w.solanaAddress))
        let node = chain(for: me)
        let recipients: [(address: String, amount: String)] = [(address(1), "1"), (address(2), "2"), (address(3), "3"), (address(4), "4.5")]
        let plan = try await svc.planSolanaBatch(wallet: w, chain: Chain.solana, symbol: "usdc", recipients: recipients, origin: .user,
                                                 source: "payouts.csv", fromPicture: false, spl: nil, node: node)
        XCTAssertEqual(plan.chainID, "solana")
        XCTAssertNotNil(plan.solana)
        XCTAssertEqual(plan.blocks, [])
        XCTAssertEqual(plan.total, "10.5")
        XCTAssertEqual(plan.source, "payouts.csv")
        XCTAssertEqual(plan.rows.map(\.needsAccount), [false, false, true, false], "recipient 3 has no USDC account")
        XCTAssertEqual(plan.solana?.rentTotal, 2_039_280)
        XCTAssertTrue(plan.checks.contains("A transfer simulated without errors"))
        XCTAssertEqual(store.opens, 0, "a review never unlocks the key")
        XCTAssertEqual(node.submitAttempts, 0, "and never sends")

        // Row 3 is refused by the node: rows 1 and 2 are sent, row 4 never starts.
        node.refuse[2] = WalletError.rpc(code: -32002, message: "Transaction simulation failed: insufficient lamports 5, need 2039280")
        let box = PlanBox(plan)
        do {
            try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
            XCTFail("row 3 was refused")
        } catch {
            XCTAssertTrue(message(error).hasPrefix("Row 3 failed: Not enough SOL for the fee or the account rent. 2 sent before it, 1 not started."), message(error))
        }
        XCTAssertEqual(store.opens, 1, "one approval for the whole run")
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed, .failed, .ready])
        // Only what went out counts: toward the daily limit, in Activity, and as an address paid before.
        XCTAssertEqual(svc.spendLimit.spentLast24h(), 3)
        XCTAssertEqual(svc.sendLog.entries.map(\.amount).sorted(), ["1", "2"])
        XCTAssertEqual(svc.addressBook.entry(for: address(1), kind: .solana)?.payments, 1)
        XCTAssertNil(svc.addressBook.entry(for: address(3), kind: .solana))

        // Retry: a new approval, and only rows 3 and 4.
        node.refuse = [:]
        try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
        XCTAssertEqual(store.opens, 2, "Retry asks again")
        XCTAssertTrue(box.plan.done)
        XCTAssertEqual(node.accepted.count, 4)
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [1_000_000, 2_000_000, 3_000_000, 4_500_000])
        XCTAssertEqual(node.sentBeforeConfirmed, 0)
        XCTAssertTrue(node.accepted.allSatisfy { $0.verifySignature() && $0.message.accountKeys[0] == me })
        XCTAssertEqual(node.accepted[2].message.instructions.count, 4, "row 3 opens the account in the same transaction")
        XCTAssertEqual(svc.spendLimit.spentLast24h(), Decimal(string: "10.5"))
        XCTAssertEqual(svc.sendLog.entries.count, 4)
        // A finished batch sends nothing more, and asks for nothing.
        try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
        XCTAssertEqual(store.opens, 2)
        XCTAssertEqual(node.accepted.count, 4)
    }

    /// The daily limit is checked again at approval (other sends may have gone out since the review), before the key is
    /// asked for. And a row a cut-short run left as sent is looked up and counted, never sent again.
    func testApprovalRechecksTheLimitAndInterruptedRows() async throws {
        let store = CountingStore()
        let svc = service(store)
        let w = try svc.importWallet(phrase: phrase, name: "T")
        let me = try XCTUnwrap(SolanaPublicKey(w.solanaAddress))
        let node = chain(for: me)
        let recipients: [(address: String, amount: String)] = [(address(1), "1"), (address(2), "2")]
        var plan = try await svc.planSolanaBatch(wallet: w, chain: Chain.solana, symbol: "USDC", recipients: recipients, origin: .user,
                                                 source: nil, fromPicture: false, spl: nil, node: node)
        XCTAssertEqual(plan.blocks, [], "reviewed with the whole $500 left")
        // By the time it is approved, $498 went out some other way: $3 no longer fits.
        svc.spendLimit.record(usd: 498)
        do {
            try await svc.runSolanaBatch(plan, node: node, pause: { _ in }) { _ in }
            XCTFail("over the limit by now")
        } catch {
            XCTAssertEqual(message(error), "Over your daily limit: $2 of $500 left today, and what is left of this batch is $3. Nothing was sent.")
        }
        XCTAssertEqual(store.opens, 0, "no approval is asked for a batch that can't go")
        XCTAssertEqual(node.submitAttempts, 0)
        svc.spendLimit.refund(usd: 498)
        XCTAssertEqual(svc.spendLimit.spentLast24h(), 0)

        // The app was closed right after row 1 went out: the saved batch has it as sent, with its id, and nothing counted.
        plan.rows[0].status = .sent
        plan.rows[0].hash = "idOfRow1"
        plan.rows[0].lastValid = node.lastValid
        node.land("idOfRow1", .confirmed)
        let box = PlanBox(plan)
        try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
        XCTAssertEqual(box.statuses, [.confirmed, .confirmed])
        XCTAssertEqual(node.accepted.map { moved($0).amount }, [2_000_000], "row 1 is looked up, not sent again")
        XCTAssertEqual(store.opens, 1)
        XCTAssertEqual(svc.spendLimit.spentLast24h(), 3, "and it counts toward the daily limit now")
        XCTAssertEqual(svc.sendLog.entries.map(\.amount).sorted(), ["1", "2"])
        XCTAssertEqual(svc.addressBook.entry(for: address(1), kind: .solana)?.payments, 1)
    }

    /// A transfer counted while it could still land, that then expires, comes off the daily limit and out of Activity:
    /// when the row goes again it is counted once.
    func testCountedThenExpiredRowIsCountedOnce() async throws {
        let svc = service(CountingStore())
        let w = try svc.importWallet(phrase: phrase, name: "T")
        let me = try XCTUnwrap(SolanaPublicKey(w.solanaAddress))
        let node = chain(for: me)
        let plan = try await svc.planSolanaBatch(wallet: w, chain: Chain.solana, symbol: "USDC", recipients: [(address(1), "5")], origin: .user,
                                                 source: nil, fromPicture: false, spl: nil, node: node)
        node.fate[0] = .never
        let box = PlanBox(plan)
        do {
            try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
            XCTFail("row 1 is unconfirmed")
        } catch { XCTAssertTrue(message(error).contains("Row 1 was sent but isn't confirmed yet"), message(error)) }
        XCTAssertEqual(box.statuses, [.sent])
        XCTAssertEqual(svc.spendLimit.spentLast24h(), 5, "it may still land, so it counts")
        XCTAssertEqual(svc.sendLog.entries.count, 1)

        // Past its last valid block and never seen: nothing moved. It goes again, after a new approval.
        node.height = node.lastValid + SolanaBatch.expiryMargin + 1
        node.fate = [:]
        try await svc.runSolanaBatch(box.plan, node: node, pause: { _ in }) { row in box.apply(row) }
        XCTAssertTrue(box.plan.done)
        XCTAssertEqual(node.accepted.count, 2, "the expired one, then the one that landed")
        XCTAssertEqual(svc.spendLimit.spentLast24h(), 5, "counted once")
        XCTAssertEqual(svc.sendLog.entries.map { Optional($0.hash) }, [box.plan.rows[0].hash], "Activity lists only the transfer that landed")
    }

    func testWalletGuards() async throws {
        let store = CountingStore()
        let svc = service(store)
        let w = try svc.importWallet(phrase: phrase, name: "T")
        let me = try XCTUnwrap(SolanaPublicKey(w.solanaAddress))
        func planned(_ recipients: [(address: String, amount: String)], symbol: String = "USDC", node: FakeSolanaNode,
                     spl: SolanaBatch.Token? = nil) async throws -> BatchPlan {
            try await svc.planSolanaBatch(wallet: w, chain: Chain.solana, symbol: symbol, recipients: recipients, origin: .user, source: nil,
                                          fromPicture: false, spl: spl, node: node)
        }
        // More than 50 recipients: refused before anything is read.
        let many: [(address: String, amount: String)] = (1...51).map { (address(UInt8($0)), "1") }
        do { _ = try await planned(many, node: chain(for: me)); XCTFail("over the limit") } catch {
            XCTAssertEqual(message(error), "That's 51 recipients. A Solana batch takes up to 50; split the list.")
        }
        // More than the balance: a block on the review, and nothing can be approved.
        let poor = try await planned([(address(1), "60"), (address(2), "50")], node: chain(for: me, balance: 100_000_000))
        XCTAssertEqual(poor.blocks, ["Not enough USDC: the list needs 110, this wallet has 100."])
        do {
            try await svc.runSolanaBatch(poor, node: chain(for: me), pause: { _ in }) { _ in }
            XCTFail("a blocked plan never runs")
        } catch { XCTAssertEqual(message(error), "Not enough USDC: the list needs 110, this wallet has 100.") }
        XCTAssertEqual(store.opens, 0)
        // A failed simulation blocks the review.
        let bad = chain(for: me)
        bad.simulation = "Not enough balance for the amount and fee."
        let simulated = try await planned([(address(1), "1")], node: bad)
        XCTAssertEqual(simulated.blocks, ["Simulation failed: Not enough balance for the amount and fee."])
        // A Token-2022 mint is refused in words, and a token Hermit doesn't know needs its mint from the caller.
        let t22 = chain(for: me)
        let odd = SolanaBatch.Token(mint: address(60), symbol: "ODD", decimals: 6, usd: 1, verified: false)
        t22.accounts[odd.mint] = SolanaAccountSummary(owner: SolanaPrograms.token2022, lamports: 1, parsedType: "mint", mintDecimals: 6)
        do { _ = try await planned([(address(1), "1")], symbol: "ODD", node: t22, spl: odd); XCTFail("Token-2022") } catch {
            XCTAssertEqual(message(error), "ODD is a Token-2022 token. Batch sends work with classic SPL tokens for now.")
        }
        do { _ = try await planned([(address(1), "1")], symbol: "ODD", node: t22); XCTFail("unknown token") } catch {
            XCTAssertEqual(error as? WalletError, .unknownToken)
        }
        // A held classic SPL token goes through with the mint's own decimals and the caller's price.
        let held = chain(for: me)
        let bonk = SolanaBatch.Token(mint: address(61), symbol: "BONK", decimals: 5, usd: Decimal(string: "0.00002"), verified: true)
        held.accounts[bonk.mint] = SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 1, parsedType: "mint", mintDecimals: 5)
        let mine = SolanaPublicKey.associatedTokenAccount(owner: me, mint: key(61))
        held.accounts[mine.description] = SolanaAccountSummary(owner: SolanaPrograms.token, lamports: 2_039_280, parsedType: "account", tokenMint: bonk.mint,
                                                               tokenOwner: me.description, tokenAmount: 5_000_000_00000, tokenState: "initialized")
        let p = try await planned([(address(1), "1000000.5"), (address(2), "250000")], symbol: "BONK", node: held, spl: bonk)
        XCTAssertEqual(p.blocks, [])
        XCTAssertEqual(p.total, "1250000.5")
        XCTAssertEqual(p.decimals, 5)
        XCTAssertEqual(p.tokenAddress, bonk.mint)
        XCTAssertEqual(p.rows.map(\.needsAccount), [true, true], "neither recipient holds BONK yet")
        XCTAssertEqual(p.solana?.rentTotal, 4_078_560)
        XCTAssertTrue(p.checks.contains { $0.hasPrefix("Within daily limit") }, "priced at the caller's price: about $25 of the $500")
        XCTAssertEqual(p.unitUSD, "0.00002")
        // Decimals that don't match the chain are refused.
        let wrong = SolanaBatch.Token(mint: bonk.mint, symbol: "BONK", decimals: 6, usd: 1, verified: true)
        do { _ = try await planned([(address(1), "1")], symbol: "BONK", node: held, spl: wrong); XCTFail("wrong decimals") } catch {
            XCTAssertTrue(message(error).contains("decimals on chain don't match"), message(error))
        }
    }

    /// The public entry point sends Solana lists to the Solana planner, and still refuses networks without batches.
    func testRouting() async {
        XCTAssertTrue(WalletService.batchSupported(.solana))
        XCTAssertTrue(WalletService.batchSupported(.solanaDevnet))
        XCTAssertTrue(WalletService.batchSupported(.base))
        XCTAssertFalse(WalletService.batchSupported(.near))
        let svc = service(HermitWallet.MemoryStore())
        _ = try? svc.importWallet(phrase: phrase, name: "T")
        // Over the Solana limit: the Solana planner answers (its limit, not EVM's 200), before any network call.
        let many: [(address: String, amount: String)] = (1...51).map { (address(UInt8($0)), "1") }
        do {
            _ = try await svc.planBatch(walletID: nil, chain: .solana, symbol: "USDC", recipients: many, origin: .user)
            XCTFail("over the Solana limit")
        } catch { XCTAssertTrue(message(error).contains("A Solana batch takes up to 50"), message(error)) }
        do {
            _ = try await svc.planBatch(walletID: nil, chain: .near, symbol: "USDC", recipients: [("alice.near", "1")], origin: .user)
            XCTFail("NEAR has no batches")
        } catch { XCTAssertTrue(message(error).contains("On NEAR, send one at a time"), message(error)) }
    }
}
