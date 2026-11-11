import XCTest
@testable import HermitWallet

/// Relay's steps are checked against what the user asked for before anything is signed. The good shapes are from live
/// quotes (2026-11-11: Base USDC to Hyperliquid, Base ETH to Arbitrum, Solana USDC to Base); each tampered one changes
/// one thing.
final class RelayTests: XCTestCase {
    let user = "0x000000000000000000000000000000000000dead"
    let depository = EVMAddress("0x4cd00e387622c35bddb9b4c962c136462338bc31")!
    let usdc = Chain.base.token("USDC")!
    var usdcAddress: EVMAddress { EVMAddress(usdc.address)! }
    let amount: UInt128 = 20_000_000

    func approve(_ spender: EVMAddress, _ n: UInt128) -> ContractCall {
        ContractCall(to: usdcAddress, data: ERC20.selector("approve(address,uint256)") + ERC20.word(spender) + ERC20.word(n), label: "Allow")
    }
    var deposit: ContractCall {
        ContractCall(to: depository, data: [0xe8, 0x01, 0x79, 0x52] + ERC20.word(EVMAddress(user)!), label: "Move")
    }
    func check(_ steps: [Relay.Step], token: Token?, amount: UInt128? = nil, user: String? = nil, from: Relay.Place = .chain(.base)) throws {
        try Relay.check(steps, from: from, fromToken: token, amount: amount ?? self.amount, user: user ?? self.user)
    }
    func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> String {
        do { try body() } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        XCTFail("expected a refusal", file: file, line: line)
        return ""
    }

    func testRealShapesPass() throws {
        XCTAssertNoThrow(try check([.evm(chainID: 8453, calls: [approve(depository, amount), deposit])], token: usdc))
        let native = ContractCall(to: depository, data: [0x49, 0x29, 0x0c, 0x1c] + ERC20.word(EVMAddress(user)!), value: 10_000_000_000_000_000, label: "Move")
        XCTAssertNoThrow(try check([.evm(chainID: 8453, calls: [native])], token: nil, amount: 10_000_000_000_000_000))
    }

    func testTamperedEVMStepsAreRefused() throws {
        let other = EVMAddress("0x1111111111111111111111111111111111111111")!
        // Allowance for an address nothing later calls, more than asked, or unlimited.
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [approve(other, amount), deposit])], token: usdc) }.contains("unknown address"))
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [approve(depository, amount + 1), deposit])], token: usdc) }.contains("uses your USDC"))
        let unlimited = ContractCall(to: usdcAddress, data: ERC20.selector("approve(address,uint256)") + ERC20.word(depository)
                                     + [UInt8](repeating: 0xff, count: 32), label: "Allow")
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [unlimited, deposit])], token: usdc) }.contains("uses your USDC"))
        // A transfer of some other token, or an NFT approval, anywhere in the list.
        let usdt = ContractCall(to: other, data: ERC20.transfer(to: other, amount: 1), label: "x")
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [approve(depository, amount), deposit, usdt])], token: usdc) }.contains("moves or unlocks"))
        let nft = ContractCall(to: other, data: ERC20.selector("setApprovalForAll(address,bool)") + ERC20.word(other) + ERC20.word(UInt128(1)), label: "x")
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [nft])], token: usdc) }.contains("moves or unlocks"))
        // A call to the user's own address, native value on a token route or over the amount, and another network.
        let own = ContractCall(to: EVMAddress(user)!, data: [], value: 0, label: "x")
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [own])], token: usdc) }.contains("own address"))
        let paid = ContractCall(to: depository, data: deposit.data, value: 1, label: "x")
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [approve(depository, amount), paid])], token: usdc) }.contains("more than you asked"))
        XCTAssertTrue(refusal { try check([.evm(chainID: 8453, calls: [paid, paid])], token: nil, amount: 1) }.contains("more than you asked"))
        XCTAssertTrue(refusal { try check([.evm(chainID: 42161, calls: [approve(depository, amount), deposit])], token: usdc) }.contains("another network"))
    }

    func testSolanaSteps() throws {
        let me = SolanaPublicKey("HP9nTkyazWmVCdszf1xhtnhe4EauzZ6z3uZtsoWLxYHe")!
        let relay = SolanaPublicKey(Relay.solanaProgram)!, other = SolanaPublicKey(bytes: [UInt8](repeating: 7, count: 32))
        let solUSDC = Chain.solana.token("USDC")!
        let dep = SolanaInstruction(program: relay, accounts: [.init(other, signer: false, writable: false), .init(me, signer: true, writable: true)],
                                    data: [0x0b, 0x9c, 0x60, 0xda])
        XCTAssertNoThrow(try check([.solana(instructions: [dep])], token: solUSDC, user: me.description, from: .chain(.solana)))
        // An unknown program with the wallet as signer.
        let unknown = SolanaInstruction(program: other, accounts: [.init(me, signer: true, writable: true)], data: [])
        XCTAssertTrue(refusal { try check([.solana(instructions: [dep, unknown])], token: solUSDC, user: me.description, from: .chain(.solana)) }
            .contains("program a swap doesn't use"))
        // SOL sent straight out beyond the amount, and an SPL Approve.
        let pay = SolanaInstruction(program: .systemProgram, accounts: [.init(me, signer: true, writable: true), .init(other, signer: false, writable: true)],
                                    data: [2, 0, 0, 0] + UInt64(1_000).littleEndianBytes(width: 8))
        XCTAssertTrue(refusal { try check([.solana(instructions: [dep, pay])], token: solUSDC, user: me.description, from: .chain(.solana)) }
            .contains("more SOL"))
        XCTAssertNoThrow(try check([.solana(instructions: [pay])], token: nil, amount: 1_000, user: me.description, from: .chain(.solana)))
        let delegate = SolanaInstruction(program: .tokenProgram, accounts: [.init(other, signer: false, writable: true), .init(me, signer: true, writable: false)],
                                         data: [4] + UInt64.max.littleEndianBytes(width: 8))
        XCTAssertTrue(refusal { try check([.solana(instructions: [dep, delegate])], token: solUSDC, user: me.description, from: .chain(.solana)) }
            .contains("token account"))
        // Solana instructions on an EVM origin.
        XCTAssertTrue(refusal { try check([.solana(instructions: [dep])], token: usdc) }.contains("another network"))
    }
}
