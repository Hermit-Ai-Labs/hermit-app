import XCTest
@testable import HermitWallet

/// What Hermit checks in Jupiter's swap transaction before Face ID. The real transactions and the simulation are the
/// mainnet fixtures SolanaDappTests reads (Fixtures/solana, 2026-11-10); the tampered ones add one instruction each.
final class JupiterTests: XCTestCase {
    func fixture(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solana"))
        return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }
    func tx(_ i: Int) throws -> SolanaWireTransaction {
        let b64 = try XCTUnwrap(try fixture("jupiter-v0")["txs"]?[i]?["tx"]?.string)
        return try SolanaWireTransaction.parse([UInt8](try XCTUnwrap(Data(base64Encoded: b64))))
    }

    /// The first fixture sells 180.17 H1kX… for about 0.0046 SOL.
    let token = Jupiter.Token(mint: "H1kXUqEPkQNNeNjGNN5tuHf3nsQK2vB1jUA9c4RggpUf", symbol: "H1KX", name: "H1KX", decimals: 9, verified: true)
    func quote(_ input: Jupiter.Token, _ output: Jupiter.Token, inAmount: UInt64, outAmount: UInt64) -> Jupiter.Quote {
        Jupiter.Quote(input: input, output: output, inAmount: inAmount, outAmount: outAmount, priceImpactPct: 0, slippageBps: 50, route: [], raw: Data())
    }
    var sell: Jupiter.Quote { quote(token, Jupiter.sol, inAmount: 180_166_588_062, outAmount: 4_650_000) }

    /// The message with more instructions (and static keys) added.
    func adding(_ m: SolanaWireMessage, keys: [SolanaPublicKey] = [], _ ixs: [SolanaCompiledInstruction], signers: Int? = nil) -> SolanaWireMessage {
        SolanaWireMessage(version: m.version, numRequiredSignatures: signers ?? m.numRequiredSignatures, numReadonlySigned: m.numReadonlySigned,
                          numReadonlyUnsigned: m.numReadonlyUnsigned, staticKeys: m.staticKeys + keys, recentBlockhash: m.recentBlockhash,
                          instructions: m.instructions + ixs, lookups: m.lookups, config: m.config, bytes: m.bytes)
    }
    func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> String {
        do { try body() } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        XCTFail("expected a refusal", file: file, line: line)
        return ""
    }

    func testRealJupiterTransactionsPass() throws {
        let m = try tx(0).message
        XCTAssertNoThrow(try Jupiter.checkTransaction(m, wallet: m.feePayer, quote: sell))
        // The third fixture tips 1000 lamports with a System transfer: well inside the 0.01 SOL allowance.
        let m3 = try tx(2).message
        XCTAssertNoThrow(try Jupiter.checkTransaction(m3, wallet: m3.feePayer, quote: sell))
    }

    func testTamperedTransactionsAreRefused() throws {
        let m = try tx(0).message, me = m.feePayer
        let tokenIx = try XCTUnwrap(m.staticKeys.firstIndex(of: .tokenProgram))
        let systemIx = try XCTUnwrap(m.staticKeys.firstIndex(of: .systemProgram))
        let budgetIx = try XCTUnwrap(m.staticKeys.firstIndex(of: .computeBudgetProgram))
        // Not this wallet's transaction, or it needs a second signer (the second fixture).
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(m, wallet: m.staticKeys[1], quote: sell) }.contains("another account pays"))
        let m2 = try tx(1).message
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(m2, wallet: m2.feePayer, quote: sell) }.contains("another signer"))
        // An unknown program.
        let other = SolanaPublicKey(bytes: [UInt8](repeating: 7, count: 32))
        let unknown = adding(m, keys: [other], [SolanaCompiledInstruction(programIndex: m.staticKeys.count, accounts: [0], data: [1])])
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(unknown, wallet: me, quote: sell) }.contains("program a swap doesn't use"))
        // SPL Token Approve (a delegate on the wallet's token account) and SetAuthority.
        for tag: UInt8 in [4, 6, 13] {
            let t = adding(m, [SolanaCompiledInstruction(programIndex: tokenIx, accounts: [1, 2, 0], data: [tag] + UInt64.max.littleEndianBytes(width: 8))])
            XCTAssertTrue(refusal { try Jupiter.checkTransaction(t, wallet: me, quote: sell) }.contains("SPL Token instruction \(tag)"))
        }
        // CloseAccount that pays the rent to someone else.
        let close = adding(m, [SolanaCompiledInstruction(programIndex: tokenIx, accounts: [1, 2, 0], data: [9])])
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(close, wallet: me, quote: sell) }.contains("closes a token account"))
        // 1 SOL straight out of the wallet on a token sale, and a System Assign.
        let transfer = adding(m, [SolanaCompiledInstruction(programIndex: systemIx, accounts: [0, 2],
                                                           data: [2, 0, 0, 0] + UInt64(1_000_000_000).littleEndianBytes(width: 8))])
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(transfer, wallet: me, quote: sell) }.contains("more SOL"))
        // The same transfer is fine when it's the SOL being swapped.
        XCTAssertNoThrow(try Jupiter.checkTransaction(transfer, wallet: me, quote: quote(Jupiter.sol, token, inAmount: 1_000_000_000, outAmount: 1)))
        let assign = adding(m, [SolanaCompiledInstruction(programIndex: systemIx, accounts: [0], data: [1, 0, 0, 0] + other.bytes)])
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(assign, wallet: me, quote: sell) }.contains("System instruction 1"))
        // A priority fee of 14 SOL (1.4M units at 10,000 lamports each).
        let fee = adding(m, [SolanaCompiledInstruction(programIndex: budgetIx, accounts: [], data: [3] + UInt64(10_000_000_000).littleEndianBytes(width: 8))])
        XCTAssertTrue(refusal { try Jupiter.checkTransaction(fee, wallet: me, quote: sell) }.contains("priority fee"))
    }

    func testSimulationMustMatchTheQuote() throws {
        let m = try tx(0).message, me = m.feePayer
        let sim = SolanaSimResult(json: try fixture("jupiter-v0-sim"))
        // Recorded: +4,607,468 lamports, −180,166,588,062 of the token.
        XCTAssertTrue(try Jupiter.checkSimulation(sim, keys: m.staticKeys, wallet: me, quote: sell))
        // It takes more of the token than quoted.
        let less = quote(token, Jupiter.sol, inAmount: 100_000_000_000, outAmount: 4_650_000)
        XCTAssertTrue(refusal { _ = try Jupiter.checkSimulation(sim, keys: m.staticKeys, wallet: me, quote: less) }.contains("more H1KX"))
        // It pays out far less SOL than quoted.
        let more = quote(token, Jupiter.sol, inAmount: 180_166_588_062, outAmount: 1_000_000_000)
        XCTAssertTrue(refusal { _ = try Jupiter.checkSimulation(sim, keys: m.staticKeys, wallet: me, quote: more) }.contains("less SOL"))
        // A buy of the token that the run shows selling it.
        let buy = quote(Jupiter.sol, token, inAmount: 10_000_000, outAmount: 1)
        XCTAssertTrue(refusal { _ = try Jupiter.checkSimulation(sim, keys: m.staticKeys, wallet: me, quote: buy) }.contains("less H1KX"))
        // A failed run says why; slippage in plain words.
        let failed = SolanaSimResult(json: ["err": ["InstructionError": [3, ["Custom": 6001]]], "logs": []])
        XCTAssertTrue(refusal { _ = try Jupiter.checkSimulation(failed, keys: m.staticKeys, wallet: me, quote: sell) }.contains("price moved"))
        // A node without balances leaves only the transaction checks.
        XCTAssertFalse(try Jupiter.checkSimulation(SolanaSimResult(json: ["err": .null]), keys: m.staticKeys, wallet: me, quote: sell))
    }
}
