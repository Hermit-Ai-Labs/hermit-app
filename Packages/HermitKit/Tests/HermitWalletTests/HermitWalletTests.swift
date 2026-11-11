import XCTest
import CryptoKit
@testable import HermitWallet

/// Vectors: BIP-39 (trezor/python-mnemonic vectors.json), BIP-32 (BIP-32 test vectors 1 and 2), SLIP-10 ed25519
/// (SLIP-0010 test vector 1), EIP-155 (the example in the EIP), Solana cookbook BIP-44 example. EIP-1559 and the
/// Solana messages / ATAs were cross-checked against eth-account 0.13 and solders (independent implementations).
final class CryptoVectorTests: XCTestCase {
    let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testKeccak() {
        XCTAssertEqual(Hash.keccak256([]).hex, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(ERC20.selector("transfer(address,uint256)").hex, "a9059cbb")
        XCTAssertEqual(ERC20.selector("balanceOf(address)").hex, "70a08231")
    }

    func testBIP39Vectors() throws {
        let vectors: [(String, String, String)] = [
            ("00000000000000000000000000000000", abandon,
             "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"),
            ("ffffffffffffffffffffffffffffffff", "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
             "ac27495480225222079d7be181583751e86f571027b0497b5b5d11218e0a8a13332572917f0f8e5a589620c6f15b11c61dee327651a14c34e18231052e48c069"),
            ("9e885d952ad362caeb4efe34a8e91bd2", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
             "274ddc525802f7c828d8ef7ddbcdc5304e87ac3535913611fbbfa986d0c9e5476c91689f9c8a54fd55bd38606aa6a8595ad213d4c9c9f9aca3fb217069a41028"),
            ("f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
             "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold",
             "01f5bced59dec48e362f2c45b5de68b9fd6c92c6634f44d6d40aab69056506f0e35524a518034ddc1192e1dacd32c1ed3eaa3c3b131c88ed8e7e54c49a5d0998"),
        ]
        for (entropy, phrase, seed) in vectors {
            XCTAssertEqual(try Mnemonic.phrase(fromEntropy: [UInt8](hex: entropy)!), phrase)
            XCTAssertEqual(try Mnemonic.entropy(fromPhrase: phrase).hex, entropy)
            XCTAssertEqual(Mnemonic.seed(phrase: phrase, passphrase: "TREZOR").hex, seed)
        }
        XCTAssertEqual(Mnemonic.seed(phrase: abandon).hex,
                       "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4")
        XCTAssertFalse(Mnemonic.isValid("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"))
        XCTAssertFalse(Mnemonic.isValid("abandon abandon abandon"))
        XCTAssertTrue(Mnemonic.isValid("  Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ABOUT \n"))
        let e = try Mnemonic.randomEntropy(words: 24)
        XCTAssertEqual(e.count, 32)
        XCTAssertEqual(try Mnemonic.phrase(fromEntropy: e).split(separator: " ").count, 24)
    }

    func testBIP32Vectors() throws {
        XCTAssertEqual(try HD.secp256k1Key(seed: [UInt8](hex: "000102030405060708090a0b0c0d0e0f")!, path: "m/0'/1/2'/2/1000000000").hex,
                       "471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c8")
        let seed2 = [UInt8](hex: "fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542")!
        XCTAssertEqual(try HD.secp256k1Key(seed: seed2, path: "m/0/2147483647'/1/2147483646'/2").hex,
                       "bb7d39bdb83ecf58f2fd82b6d918341cbef428661ef01ab97c28a4842125ac23")
        XCTAssertThrowsError(try HD.parse("44'/60'"))
    }

    func testSLIP10Ed25519Vector() throws {
        let seed = [UInt8](hex: "000102030405060708090a0b0c0d0e0f")!
        XCTAssertEqual(try HD.ed25519Seed(seed: seed, path: "m").hex, "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
        XCTAssertEqual(try HD.ed25519Seed(seed: seed, path: "m/0'").hex, "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3")
        XCTAssertEqual(try HD.ed25519Seed(seed: seed, path: "m/0'/1'/2'/2'/1000000000'").hex,
                       "8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793")
        XCTAssertThrowsError(try HD.ed25519Seed(seed: seed, path: "m/0"))
    }

    /// Same addresses MetaMask / Phantom / Solflare show for these phrases.
    func testMnemonicToAddresses() throws {
        let a = try KeyVault.addresses(phrase: abandon)
        XCTAssertEqual(a.evm, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        XCTAssertEqual(a.solana, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        // Solana cookbook "restore from mnemonic" BIP-44 example, m/44'/501'/0'/0'.
        let b = try KeyVault.addresses(phrase: "neither lonely flavor argue grass remind eye tag avocado spot unusual intact")
        XCTAssertEqual(b.solana, "5vftMkHL72JaJG6ExQfGAsT2uGVHpRR7oTNUPMs68Y2N")
    }

    func testEIP55() {
        for a in ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
                  "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"] {
            XCTAssertEqual(EVMAddress(a)?.checksummed, a)
            XCTAssertNotNil(EVMAddress(a.lowercased()))
        }
        XCTAssertNil(EVMAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD")) // bad checksum
        XCTAssertNil(EVMAddress("0x1234"))
    }

    /// The example transaction from EIP-155 (legacy, chain 1), signed through our RLP + secp256k1 code.
    func testEIP155Vector() throws {
        let key = [UInt8](repeating: 0x46, count: 32)
        let fields: [RLP] = [.uint(UInt64(9)), .uint(UInt64(20_000_000_000)), .uint(UInt64(21000)),
                             .bytes([UInt8](repeating: 0x35, count: 20)), .uint(UInt128(1_000_000_000_000_000_000)), .bytes([])]
        let sigHash = Hash.keccak256(RLP.list(fields + [.uint(UInt64(1)), .bytes([]), .bytes([])]).encoded)
        XCTAssertEqual(sigHash.hex, "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53")
        let (rs, recid) = try Secp256k1.sign(digest: sigHash, key: key)
        let raw = RLP.list(fields + [.uint(UInt64(37 + recid - 0)), .bytes(stripZeros(Array(rs[0..<32]))), .bytes(stripZeros(Array(rs[32...])))]).encoded
        XCTAssertEqual(raw.hex, "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83")
        XCTAssertEqual(EVMAddress(publicKey: try Secp256k1.publicKey(of: key, compressed: false)).checksummed,
                       "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
    }

    func testEIP1559USDCTransfer() throws {
        let key = [UInt8](repeating: 0x46, count: 32)
        let tx = EIP1559Transaction(chainId: 84532, nonce: 7, maxPriorityFeePerGas: 1_000_000, maxFeePerGas: 2_000_000_000, gasLimit: 65000,
                                    to: EVMAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e")!, value: 0,
                                    data: ERC20.transfer(to: EVMAddress(bytes: [UInt8](repeating: 0x35, count: 20)), amount: 1_500_000))
        let s = try tx.sign(privateKey: key)
        XCTAssertEqual(s.raw.hex, "02f8b183014a3407830f4240847735940082fde894036cbd53842c5426634e7929541ec2318f3dcf7e80b844a9059cbb0000000000000000000000003535353535353535353535353535353535353535000000000000000000000000000000000000000000000000000000000016e360c080a0b856affed5838b320de45c751a9feaa6c36ba86a033240b603a58314425be87ca02a19c907b5576de631f16b44773bd369fcf158746ac80cbebd9bdabb2194583c")
        XCTAssertEqual(s.hash, "0x7862303b621ba98b56071f2e3862e84c6e1117ed5734f12462e8b8c83b10a567")
        let d = try XCTUnwrap(EIP1559Transaction.decode(raw: s.raw))
        XCTAssertEqual(d.tx, tx)
        XCTAssertEqual(d.sender?.checksummed, "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
        let (to, amt) = try XCTUnwrap(ERC20.decodeTransfer(d.tx.data))
        XCTAssertEqual(to.bytes, [UInt8](repeating: 0x35, count: 20)); XCTAssertEqual(amt, 1_500_000)
    }

    func testEIP1559NativeTransfer() throws {
        let tx = EIP1559Transaction(chainId: 1, nonce: 0, maxPriorityFeePerGas: 2_000_000_000, maxFeePerGas: 30_000_000_000, gasLimit: 21000,
                                    to: EVMAddress(bytes: [UInt8](repeating: 0x35, count: 20)), value: 1_000_000_000_000_000_000, data: [])
        XCTAssertEqual(try tx.sign(privateKey: [UInt8](repeating: 0x46, count: 32)).raw.hex,
                       "02f873018084773594008506fc23ac00825208943535353535353535353535353535353535353535880de0b6b3a764000080c001a0829525dceb1901a95153c0762c65162a51ef1e52f1e3db3db5e180aeb162807ea01266d552e7118abffd4e0c1d060ba1d96f2f8ad87caf73ebae55e868db89f4d5")
    }

    func testRLP() {
        XCTAssertEqual(RLP.bytes(Array("dog".utf8)).encoded.hex, "83646f67")
        XCTAssertEqual(RLP.list([.bytes(Array("cat".utf8)), .bytes(Array("dog".utf8))]).encoded.hex, "c88363617483646f67")
        XCTAssertEqual(RLP.bytes([]).encoded.hex, "80")
        XCTAssertEqual(RLP.uint(UInt64(1024)).encoded.hex, "820400")
        XCTAssertEqual(RLP.list([]).encoded.hex, "c0")
        let long = RLP.bytes(Array("Lorem ipsum dolor sit amet, consectetur adipisicing elit".utf8))
        XCTAssertEqual(long.encoded.prefix(2).map { $0 }.hex, "b838")
        XCTAssertEqual(RLP.decode(long.encoded), long)
        XCTAssertNil(RLP.decode([0x81, 0x05])) // non-canonical single byte
    }

    func testUnits() throws {
        XCTAssertEqual(try Units.parse("1.5", decimals: 6), 1_500_000)
        XCTAssertEqual(try Units.parse("0.000001", decimals: 6), 1)
        XCTAssertEqual(try Units.parse("1000", decimals: 18), 1_000_000_000_000_000_000_000)
        XCTAssertEqual(try Units.parse(".5", decimals: 9), 500_000_000)
        for bad in ["", "-1", "1.0000001", "1e5", "abc", "1.2.3", ".", "1,000", "1,5", "25,5"] { XCTAssertThrowsError(try Units.parse(bad, decimals: 6), bad) }
        XCTAssertEqual(Units.format(1_500_000, decimals: 6), "1.5")
        XCTAssertEqual(Units.format(1, decimals: 18), "0.000000000000000001")
        XCTAssertEqual(Units.format(1, decimals: 18, maxFraction: 6), "0")
        XCTAssertEqual(Units.format(42_000_000, decimals: 6), "42")
    }
}

final class SolanaTests: XCTestCase {
    let owner = SolanaPublicKey("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")!
    let to = SolanaPublicKey("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM")!
    let usdc = SolanaPublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")!
    let blockhash = Base58.decode("EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N")!

    func testBase58() {
        XCTAssertEqual(Base58.encode([0, 0, 0x28, 0x7f, 0xb4, 0xcd]), "11233QC4")
        XCTAssertEqual(Base58.decode("11233QC4"), [0, 0, 0x28, 0x7f, 0xb4, 0xcd])
        XCTAssertEqual(SolanaPublicKey.systemProgram.bytes, [UInt8](repeating: 0, count: 32))
        XCTAssertNil(Base58.decode("0OIl"))
        XCTAssertNil(SolanaPublicKey("abc"))
    }

    func testOnCurve() {
        let v: [(String, Bool)] = [
            ("52f22665a60c12d289185d950ee8813609166f6b113d178d6c0fd3901ff239a1", false),
            ("a095f20f9395650cf9380b8edb224a6b248a1e924e8fd0ae2e1a9492a3305f18", false),
            ("8cb610900f9e347fae886dc6507795ec745c4c3fcb2eb2c73e14934c867ee057", true),
            ("ba72499bfa121e836b2ac15726ee7d6b0af6ab13c38e92cae0d15057b159987f", false),
            ("94cc7411d717f14579b2aa100fbbb34fa593feaed27248b762e3ab5805f0765a", true),
            ("2b9c1d7e0f37c44921bd3f6564eadf7f142a72668c47e223d16edd8c47b46afc", true),
            ("5baee261f53b26152d263ba83b037cd4962e434801256b885e9c9051f320b0db", false),
            ("83f39ea7adbd0d74e6dec7f3dfaecc8f646566641a7ba2660f3011fc3570291c", false),
            ("57990d1a0091268919f25d9d0612df359d6026a240f4589a5d791f1dd97cfefa", true),
            ("777a7b4f15241abf57bd437ad4b129840534f3f3875c25b08bea06c2874cfaa4", false),
        ]
        for (h, on) in v { XCTAssertEqual(Ed25519Curve.isOnCurve([UInt8](hex: h)!), on, h) }
        XCTAssertTrue(owner.isOnCurve) // every wallet key is on the curve
        XCTAssertTrue(to.isOnCurve)
    }

    func testAssociatedTokenAccount() {
        XCTAssertEqual(SolanaPublicKey.associatedTokenAccount(owner: owner, mint: usdc).description, "5N3f1tj9v1vc5TUZ8S7mCAnVmjVKrfnzXWhxLaxyZAgt")
        XCTAssertEqual(SolanaPublicKey.associatedTokenAccount(owner: to, mint: usdc).description, "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B")
    }

    func testSOLTransferMessageMatchesSolders() throws {
        let msg = SolanaMessage(payer: owner, instructions: [.setComputeUnitLimit(200_000), .setComputeUnitPrice(1000),
                                                             .transfer(from: owner, to: to, lamports: 1_234_567)], recentBlockhash: blockhash)
        XCTAssertEqual(msg.serialized.hex, "01000204f036276246a75b9de3349ed42b15e232f6518fc20f5fcd4f1d64e81f9bd258f77e8c088760bfde1dddcf32c17f209b8242ee52aaf131facd88d0ea2c6d0b06f200000000000000000000000000000000000000000000000000000000000000000306466fe5211732ffecadba72c39be7bc8ce5bbc5f7126b2c439b3a40000000cc490e928cd2e3873bb343fc95da33179ca60f4dbf46c2c36e91299d55d4e6b90303000502400d030003000903e803000000000000020200010c0200000087d6120000000000")
        // Sign with the key derived from the "abandon ... about" phrase and check the signature.
        let seed = Mnemonic.seed(phrase: CryptoVectorTests().abandon)
        let k = try HD.ed25519Seed(seed: seed, path: KeyVault.solanaPath)
        var tx = SolanaTransaction(message: msg)
        try tx.sign(ed25519Seed: k)
        XCTAssertTrue(tx.verifySignature())
        XCTAssertEqual(tx.serialized.count, 1 + 64 + msg.serialized.count)
        XCTAssertEqual(Base58.decode(tx.signature), tx.signatures[0])
        // A different key must not be able to sign for this payer.
        var other = SolanaTransaction(message: msg)
        XCTAssertThrowsError(try other.sign(ed25519Seed: [UInt8](repeating: 7, count: 32)))
    }

    func testSPLTransferMessageMatchesSolders() {
        let msg = SolanaMessage(payer: owner, instructions: [
            .setComputeUnitLimit(200_000), .setComputeUnitPrice(1000),
            .createAssociatedTokenAccountIdempotent(payer: owner, owner: to, mint: usdc),
            .transferChecked(source: .associatedTokenAccount(owner: owner, mint: usdc), mint: usdc,
                             destination: .associatedTokenAccount(owner: to, mint: usdc), owner: owner, amount: 2_500_000, decimals: 6),
        ], recentBlockhash: blockhash)
        XCTAssertEqual(msg.serialized.hex, "01000609f036276246a75b9de3349ed42b15e232f6518fc20f5fcd4f1d64e81f9bd258f740d2f27c461f29e9feba1ab8acd39496a9c65b0ae62a713f01f941a993bf55edd3ea8cf5acaca8cd05207512175c43cef54a5dd99ede20a16b55253738f397dc00000000000000000000000000000000000000000000000000000000000000000306466fe5211732ffecadba72c39be7bc8ce5bbc5f7126b2c439b3a4000000006ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a97e8c088760bfde1dddcf32c17f209b8242ee52aaf131facd88d0ea2c6d0b06f28c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61cc490e928cd2e3873bb343fc95da33179ca60f4dbf46c2c36e91299d55d4e6b90404000502400d030004000903e803000000000000070600020608030501010504010802000a0ca02526000000000006")
    }
}

final class TableAndVaultTests: XCTestCase {
    func testTokenTable() {
        for t in TokenTable.all {
            let chain = Chain.with(id: t.chainID)
            XCTAssertNotNil(chain, t.id)
            switch chain?.kind {
            case .evm: XCTAssertEqual(EVMAddress(t.address)?.checksummed, t.address, "\(t.id) must be EIP-55 checksummed")
            case .solana: XCTAssertNotNil(SolanaPublicKey(t.address), t.id)
            case .near: XCTAssertTrue(NearAccount.isValid(t.address), t.id)
            case nil: break
            }
        }
        XCTAssertEqual(Set(Chain.all.map(\.id)).count, Chain.all.count)
        XCTAssertEqual(Chain.defaultSend.chainId, WalletService.mainnetSendsEnabled ? 8453 : 84532)
        XCTAssertEqual(Chain.baseSepolia.token("usdc")?.address, "0x036CbD53842c5426634e7929541eC2318f3dCF7e")
        XCTAssertEqual(Chain.base.token("USDC")?.address, "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
    }

    func testVaultLifecycleInMemory() async throws {
        let vault = KeyVault(store: MemoryStore())
        let r = try vault.importPhrase(CryptoVectorTests().abandon, name: "Test")
        XCTAssertEqual(r.evmAddress, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        XCTAssertEqual(r.solanaAddress, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        XCTAssertThrowsError(try vault.importPhrase(CryptoVectorTests().abandon, name: "Again"))
        let phrase = try await vault.exportPhrase(r.id)
        XCTAssertEqual(phrase, CryptoVectorTests().abandon)
        let sender = try await vault.withKey(r.id, kind: .evm, reason: "test") { key in
            try EIP1559Transaction(chainId: 84532, nonce: 0, maxPriorityFeePerGas: 1, maxFeePerGas: 2, gasLimit: 21000,
                                   to: EVMAddress(r.evmAddress)!, value: 1, data: []).sign(privateKey: key).sender
        }
        XCTAssertEqual(sender?.checksummed, r.evmAddress)
        let created = try vault.create(name: "Fresh", words: 24)
        XCTAssertEqual(created.wordCount, 24)
        XCTAssertFalse(created.backedUp)
        let words = try await vault.exportPhrase(created.id)
        XCTAssertTrue(Mnemonic.isValid(words))
        XCTAssertEqual(try KeyVault.addresses(phrase: words).evm, created.evmAddress)
        try vault.delete(created.id)
        XCTAssertEqual(vault.wallets.map(\.id), [r.id])
    }

    func testSpendLimitAndAddressBook() {
        let d = UserDefaults(suiteName: "hermit.wallet.tests.\(UUID())")!
        let limit = SpendLimit(defaults: d)
        limit.dailyLimitUSD = 100
        limit.record(usd: 30, at: Date().addingTimeInterval(-90_000)) // older than a day
        limit.record(usd: 40)
        XCTAssertEqual(limit.remaining(), 60)
        let book = AddressBook(defaults: d)
        XCTAssertNil(book.entry(for: "0xAbC0000000000000000000000000000000000001", kind: .evm))
        book.recordPayment(to: "0xabc0000000000000000000000000000000000001", kind: .evm, label: "alice.eth")
        XCTAssertEqual(book.entry(for: "0xABC0000000000000000000000000000000000001", kind: .evm)?.payments, 1)
    }
}

/// The Secure Enclave file store, unattended: the enclave key is made without a user-presence flag so no prompt
/// is needed. Runs on Macs and devices with an enclave; skipped elsewhere (CI VMs, the simulator).
final class SecureEnclaveFileStoreTests: XCTestCase {
    func testSealOpenRemoveRoundTrip() async throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave here")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-se-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveFileStore(directory: dir, requireUserPresence: false)
        let vault = KeyVault(store: store)
        let r = try vault.importPhrase(CryptoVectorTests().abandon, name: "SE")
        XCTAssertEqual(r.protection, .secureEnclave)

        // On disk: only the enclave handle, the ephemeral key and ciphertext. The entropy is not there in the clear.
        let file = try Data(contentsOf: store.file(r.id))
        let entropy = try Mnemonic.entropy(fromPhrase: CryptoVectorTests().abandon)
        XCTAssertNil(file.range(of: Data(entropy)))
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains("abandon"))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file(r.id).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A fresh vault over the same folder reloads the index and opens the seed through the enclave.
        let again = KeyVault(store: SecureEnclaveFileStore(directory: dir, requireUserPresence: false))
        XCTAssertEqual(again.wallets.map(\.evmAddress), ["0x9858EfFD232B4033E47d90003D41EC34EcaEda94"])
        let phrase = try await again.exportPhrase(r.id)
        XCTAssertEqual(phrase, CryptoVectorTests().abandon)

        // Tampering with the box is caught by AES-GCM.
        var sealed = try JSONDecoder().decode(SecureEnclaveFileStore.Sealed.self, from: file)
        sealed.box[sealed.box.count - 1] ^= 1
        try JSONEncoder().encode(sealed).write(to: store.file(r.id))
        do { _ = try await again.exportPhrase(r.id); XCTFail("tampered seed opened") } catch {}

        try again.delete(r.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(r.id).path))
        XCTAssertTrue(again.wallets.isEmpty)
    }

    func testCreateWithPhraseMatchesExport() async throws {
        let vault = KeyVault(store: MemoryStore())
        let (r, phrase) = try vault.createWithPhrase(name: "New")
        XCTAssertEqual(phrase.split(separator: " ").count, 12)
        XCTAssertFalse(r.backedUp)
        let exported = try await vault.exportPhrase(r.id)
        XCTAssertEqual(exported, phrase)
        XCTAssertEqual(try KeyVault.addresses(phrase: phrase).solana, r.solanaAddress)
    }

    func testSendLogAndWhitelistBook() {
        let d = UserDefaults(suiteName: "hermit.wallet.tests.\(UUID())")!
        let log = SendLog(defaults: d)
        let w = UUID()
        log.record(.init(hash: "0x01", chainID: "base-sepolia", walletID: w, amount: "0.1", symbol: "ETH", recipient: "0xabc", label: nil, date: Date()))
        log.record(.init(hash: "0x02", chainID: "solana-devnet", walletID: UUID(), amount: "1", symbol: "SOL", recipient: "x", label: "bob", date: Date()))
        XCTAssertEqual(log.entries.map(\.hash), ["0x02", "0x01"])
        XCTAssertEqual(log.entries.last?.chain, .baseSepolia)
        log.remove(wallet: w)
        XCTAssertEqual(log.entries.map(\.hash), ["0x02"])

        let book = AddressBook(defaults: d)
        book.setLabel("Exchange", for: "0x00000000000000000000000000000000000000Aa", kind: .evm)
        let e = book.entry(for: "0x00000000000000000000000000000000000000aa", kind: .evm)
        XCTAssertEqual(e?.label, "Exchange")
        XCTAssertNotNil(e?.added)
        book.remove("0x00000000000000000000000000000000000000AA", kind: .evm)
        XCTAssertNil(book.entry(for: "0x00000000000000000000000000000000000000aa", kind: .evm))
    }

    @MainActor
    func testMainnetGuardBlocksWhenOff() async throws {
        let d = UserDefaults(suiteName: "hermit.wallet.tests.\(UUID())")!
        let svc = WalletService(vault: KeyVault(store: MemoryStore()), addressBook: AddressBook(defaults: d), spendLimit: SpendLimit(defaults: d),
                                sendLog: SendLog(defaults: d))
        XCTAssertEqual(svc.allowMainnetSends, WalletService.mainnetSendsEnabled)
        svc.allowMainnetSends = false
        try svc.importWallet(phrase: CryptoVectorTests().abandon)
        for c in Chain.mainnets {
            do { _ = try await svc.prepareSend(chain: c, to: c.kind == .evm ? "0x3535353535353535353535353535353535353535" : "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", amount: "1"); XCTFail(c.name) }
            catch { XCTAssertTrue("\(error)".contains("beta"), c.name) }
        }
    }
}

/// Live reads against public RPCs. Run with HERMIT_LIVE=1. Never sends anything.
final class LiveReadTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE"] == "1", "set HERMIT_LIVE=1 for live reads")
    }

    func testBaseSepolia() async throws {
        let c = EVMClient(url: Chain.baseSepolia.rpc)
        let id = try await c.chainId()
        XCTAssertEqual(id, 84532)
        let me = EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")!
        let eth = try await c.balance(me)
        let usdc = try await c.tokenBalance(token: EVMAddress(Chain.baseSepolia.token("USDC")!.address)!, owner: me)
        let fees = try await c.fees()
        let nonce = try await c.nonce(me)
        print("LIVE base-sepolia chainId=\(id) ETH=\(Units.format(eth, decimals: 18)) USDC=\(Units.format(usdc, decimals: 6)) nonce=\(nonce) baseFee=\(fees.baseFee) tip=\(fees.maxPriorityFeePerGas)")
        XCTAssertGreaterThan(fees.maxFeePerGas, 0)

        // Build and sign a USDC transfer offline with a throwaway key, decode it, and check it against estimateGas.
        let key = [UInt8](repeating: 0x46, count: 32)
        let tx = EIP1559Transaction(chainId: id, nonce: 0, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, maxFeePerGas: fees.maxFeePerGas,
                                    gasLimit: 80_000, to: EVMAddress(Chain.baseSepolia.token("USDC")!.address)!, value: 0,
                                    data: ERC20.transfer(to: me, amount: 1_000_000))
        let signed = try tx.sign(privateKey: key)
        let decoded = try XCTUnwrap(EIP1559Transaction.decode(raw: signed.raw))
        XCTAssertEqual(decoded.tx, tx)
        XCTAssertEqual(decoded.sender?.checksummed, "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
        print("LIVE signed offline (not sent): \(signed.hash) \(signed.raw.count) bytes")
    }

    func testAllChainIds() async throws {
        for chain in Chain.all where chain.kind == .evm {
            let id = try await EVMClient(url: chain.rpc).chainId()
            XCTAssertEqual(id, chain.chainId, chain.name)
            print("LIVE \(chain.name): chainId \(id)")
        }
    }

    func testTokenDecimalsOnChain() async throws {
        for t in TokenTable.all {
            guard let chain = Chain.with(id: t.chainID), chain.kind == .evm else { continue }
            let out = try await EVMClient(url: chain.rpc).call(to: EVMAddress(t.address)!, data: ERC20.selector("decimals()"))
            XCTAssertEqual(UInt128(bigEndian: out).map(Int.init), t.decimals, t.id)
        }
    }

    func testENS() async throws {
        let a = try await ENS.resolve("vitalik.eth", client: EVMClient(url: Chain.ethereum.rpc))
        print("LIVE vitalik.eth -> \(a)")
        XCTAssertEqual(a.checksummed, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
    }

    func testSolanaDevnet() async throws {
        let c = SolanaClient(url: Chain.solanaDevnet.rpc)
        let me = SolanaPublicKey("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")!
        let sol = try await c.balance(me)
        let usdc = try await c.tokenBalance(owner: me, mint: SolanaPublicKey(Chain.solanaDevnet.token("USDC")!.address)!)
        let (bh, height) = try await c.latestBlockhash()
        let fee = try await c.priorityFee(accounts: [me])
        print("LIVE solana-devnet SOL=\(Units.format(UInt128(sol), decimals: 9)) USDC=\(usdc) blockhash=\(Base58.encode(bh)) height=\(height) cuPrice=\(fee)")
        // Simulate a transfer from an unfunded wallet: must fail cleanly, and the hazard scan must say so.
        let msg = SolanaMessage(payer: me, instructions: [.setComputeUnitLimit(200_000), .transfer(from: me, to: me, lamports: 1)], recentBlockhash: bh)
        let sim = try await c.simulate(SolanaTransaction(message: msg))
        print("LIVE simulate unfunded: err=\(sim.error ?? "none")")
        if sol == 0 { XCTAssertNotNil(sim.error) }
    }

    @MainActor
    func testPrepareSendOnUnfundedWalletIsBlocked() async throws {
        let d = UserDefaults(suiteName: "hermit.wallet.live.\(UUID())")!
        let svc = WalletService(vault: KeyVault(store: MemoryStore()), addressBook: AddressBook(defaults: d), spendLimit: SpendLimit(defaults: d))
        try svc.importWallet(phrase: CryptoVectorTests().abandon)
        await svc.refreshBalances(chains: [.baseSepolia, .solanaDevnet])
        print("LIVE balances: \(svc.balances(for: .baseSepolia).map { "\($0.formatted) \($0.symbol)" }) \(svc.balances(for: .solanaDevnet).map { "\($0.formatted) \($0.symbol)" })")
        let p = try await svc.prepareSend(to: "0x3535353535353535353535353535353535353535", amount: "1.25", token: "USDC")
        print("LIVE prepared: \(p.lines) checks=\(p.checks.map { "\($0.title): \($0.detail)" })")
        // Mainnet sends are on (WalletService.mainnetSendsEnabled), so a send that names no network defaults to Base.
        XCTAssertEqual(p.chain.id, WalletService.mainnetSendsEnabled ? "base" : "base-sepolia")
        XCTAssertEqual(p.amount, 1_250_000)
        // The wallet has no ETH for gas on Base: the simulation fails, so the send is blocked and nothing can be approved.
        XCTAssertFalse(p.canSend, "\(p.checks)")
        do { _ = try svc.approval(for: p); if !p.canSend { XCTFail("approval should be refused") } } catch {}
        if !WalletService.mainnetSendsEnabled {
            do { _ = try await svc.prepareSend(chain: .base, to: "0x3535353535353535353535353535353535353535", amount: "1", token: "USDC"); XCTFail() }
            catch { XCTAssertTrue("\(error)".contains("beta")) }
        }
        let quotes = await PriceFeed().quotes()
        print("LIVE prices: \(quotes.mapValues(\.usd))")
        XCTAssertNotNil(quotes["ETH"])
        let all = await svc.fetchBalances(for: svc.wallets[0], chains: Chain.all)
        print("LIVE fetched \(all.balances.count) chains, failed: \(all.failed.map(\.name))")
        let ps = try await svc.prepareSend(chain: .solanaDevnet, to: "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", amount: "0.01", token: "USDC")
        print("LIVE prepared solana: \(ps.lines) checks=\(ps.checks.map { "\($0.title): \($0.detail)" })")
    }
}
