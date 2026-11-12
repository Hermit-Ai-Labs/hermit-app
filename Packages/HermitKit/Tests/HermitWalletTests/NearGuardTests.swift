import XCTest
import CryptoKit
@testable import HermitWallet

/// Hermit Guard, the app side (contracts/guard). Everything here runs offline.
/// - Transaction bytes come from near-api-js 4.0.4 (`transactions.addKey`, `functionAccessKey`, `deleteKey`, `functionCall`), built
///   with the same signer, nonce and block hash as `NearStakingTests`; the generator is tmp/guard-app/gen.js (outside the repo).
/// - `near-guard-*.json` fixtures are real answers from the testnet deployment hermit-guard-1794510023.testnet (read-only RPC,
///   2026-11-12), for the owner account of the recorded run in contracts/guard/DEPLOYMENTS.md. `near-guard-tx-refused.json`
///   is the real status of the refused testnet transaction 9fQjv5HS6r... (a pocket key paying over its per-payment cap).
/// - The argument shapes are checked against contracts/guard/src/lib.rs itself when that file is in the checkout.
final class NearGuardTests: XCTestCase {
    let implicit = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
    let blockHash = "4reLvkAWfqk5fsqio1KLudk46cqRz9erQdaHkWZKMJDZ"
    let guardID = "hermit-guard-1794510023.testnet"
    let gtt = "hermit-guard-ft-1794510146.testnet"
    let usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    let owner = "hermit-guard-owner-1794510146.testnet"
    let shop = "hermit-guard-shop-1794510146.testnet"
    let near: UInt128 = 1_000_000_000_000_000_000_000_000
    let wallet = UUID()
    /// Fifteen minutes after the last recorded receipt, so the "coffee" pocket's day is still open.
    let now: UInt64 = 1_794_511_200_000_000_000

    func rpc(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSON.self, from: try Data(contentsOf: url))
    }
    /// What the contract returned for a recorded view call.
    func view(_ name: String) throws -> Data { NearClient.viewBytes(try XCTUnwrap(try rpc(name)["result"])) }

    func tx(_ receiver: String, _ actions: [NearAction]) -> NearTransaction {
        NearTransaction(signer: implicit, publicKey: [UInt8](hex: implicit)!, nonce: 123_456_789, receiver: receiver,
                        blockHash: Base58.decode(blockHash)!, actions: actions)
    }

    func policy() -> SpendPolicy {
        let d = UserDefaults(suiteName: "guard-\(UUID())")!
        return SpendPolicy(limit: SpendLimit(defaults: d), book: AddressBook(defaults: d), defaults: d)
    }

    // MARK: Vectors from near-api-js

    let pocketKeyText = "ed25519:Bvu6rSsW56uKu2ECNd82JPoBGxaELY9KjwaxWbfB1m81"
    var pocketKey: [UInt8] { Hash.sha256(Array("hermit guard pocket key vector".utf8)) }

        static let vectors: [String: (hex: String, hash: String)] = [
        "add_key": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000004000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c010000000500a26390155fbf36a0b2503b7efc5b42bb8c62ba0905e3b175b82b80dd98913a2600000000000000000001000040683bb3f386f0340000000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e657402000000050000007370656e640700000072657175657374",
            hash: "CjrPPZpHjT6rZ4sBpTccktKoovFSbxQSvbRR1LpeBoYn"),
        "delete_key": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000004000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c010000000600a26390155fbf36a0b2503b7efc5b42bb8c62ba0905e3b175b82b80dd98913a26",
            hash: "G6RczhSDaVcGvcvhrNX6oEt4Ca8suhaVKZQZUviLwV6D"),
        "open_vault": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020a0000006f70656e5f7661756c74020000007b7d0060b7986c8800000000c038b219db94d19e000000000000",
            hash: "Ae7Agk2CCV9nw8DS1GKXYXKkgVPmukn1KZxLixJ9384B"),
        "deposit_near": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020c0000006465706f7369745f6e656172020000007b7d0060b7986c880000000080716433b629a33d010000000000",
            hash: "2zes41o4XZjV4BzhgvQTvSTKFED2ndEg6LQ172BdNDCr"),
        "ft_transfer_call": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000004000000031373230383632386638346635643661643333663064613362626265623237666663623339386561633530316133316264366164323031316533363133336131394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000021000000066745f7472616e736665725f63616c6c4d0000007b2272656365697665725f6964223a226865726d69742d67756172642d313739343531303032332e746573746e6574222c22616d6f756e74223a2232353030303030222c226d7367223a22227d0080f420e6b5000001000000000000000000000000000000",
            hash: "78NxQRwzUf1CLdcHZ3oZNTyWDmYS6wBfS7BR8Dg25Txa"),
        "withdraw_amount": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c0100000002080000007769746864726177350000007b22746f6b656e223a226e656172222c22616d6f756e74223a2231323530303030303030303030303030303030303030303030227d0060b7986c88000001000000000000000000000000000000",
            hash: "BJQUivP7d3qBdDjWUhnhqUcAFKEJcigNjBzx2pMdmfXe"),
        "withdraw_all": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020800000077697468647261775a0000007b22746f6b656e223a2231373230383632386638346635643661643333663064613362626265623237666663623339386561633530316133316264366164323031316533363133336131222c22616d6f756e74223a6e756c6c7d0060b7986c88000001000000000000000000000000000000",
            hash: "ETnUBzVsxCYB9x35LuUkYgGcKBA5iWfJPqxBccZznPNJ"),
        "close_vault": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020b000000636c6f73655f7661756c74020000007b7d0060b7986c88000001000000000000000000000000000000",
            hash: "Hgmzq69cgR9F9cxeQjyjqD4fQ2PeMer1Qnuh8AuSKYQP"),
        "freeze": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c010000000206000000667265657a65020000007b7d0060b7986c88000001000000000000000000000000000000",
            hash: "EmKbtZ1pLpR2Lyh7dRcnfTdmdaNSFvN1ihmLjeSKzRzk"),
        "unfreeze": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c010000000208000000756e667265657a65020000007b7d0060b7986c88000001000000000000000000000000000000",
            hash: "CKB1SkCmX9Ag3er864E5jk9uApf7ZkaN9i9LVnA6yf8p"),
        "create_pocket_key": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d0000006372656174655f706f636b6574250100007b22636f6e666967223a7b226e616d65223a22636f66666565222c227075626c69635f6b6579223a22656432353531393a42767536725373573536754b753245434e6438324a506f42477861454c59394b6a77617857626642316d3831222c22746f6b656e223a226e656172222c227065725f7061796d656e745f636170223a22353030303030303030303030303030303030303030303030222c226461696c795f636170223a2231303030303030303030303030303030303030303030303030222c22616c6c6f7765645f726563697069656e7473223a5b226865726d69742d67756172642d73686f702d313739343531303134362e746573746e6574225d2c22657870697265735f6174223a2231373934363030303030303030303030303030227d7d0060b7986c88000001000000000000000000000000000000",
            hash: "6Wv17Qi3Hmsk8RdD2YnDp9yLw2WhZYN6yCEZoAoQob7C"),
        "create_pocket_nokey": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d0000006372656174655f706f636b6574d50000007b22636f6e666967223a7b226e616d65223a2272656e74222c227075626c69635f6b6579223a6e756c6c2c22746f6b656e223a2231373230383632386638346635643661643333663064613362626265623237666663623339386561633530316133316264366164323031316533363133336131222c227065725f7061796d656e745f636170223a223530303030303030222c226461696c795f636170223a223530303030303030222c22616c6c6f7765645f726563697069656e7473223a5b5d2c22657870697265735f6174223a6e756c6c7d7d0060b7986c88000001000000000000000000000000000000",
            hash: "HDj59pUYqX5HhgxGFfRbXYrDQhDBQhnZyxVd1w4TAZYV"),
        "create_pocket_escaped": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d0000006372656174655f706f636b6574920000007b22636f6e666967223a7b226e616d65223a224b655c22747420c3a95c5c222c227075626c69635f6b6579223a6e756c6c2c22746f6b656e223a226e656172222c227065725f7061796d656e745f636170223a2231222c226461696c795f636170223a2232222c22616c6c6f7765645f726563697069656e7473223a5b5d2c22657870697265735f6174223a6e756c6c7d7d0060b7986c88000001000000000000000000000000000000",
            hash: "UnngECrHe954Dp2yH8tDVP7T8n6ePqJHp64W8UtWwqB"),
        "update_pocket": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d0000007570646174655f706f636b6574fe0000007b22636f6e666967223a7b226e616d65223a22636f66666565222c227075626c69635f6b6579223a22656432353531393a42767536725373573536754b753245434e6438324a506f42477861454c59394b6a77617857626642316d3831222c22746f6b656e223a226e656172222c227065725f7061796d656e745f636170223a22323530303030303030303030303030303030303030303030222c226461696c795f636170223a22373530303030303030303030303030303030303030303030222c22616c6c6f7765645f726563697069656e7473223a5b22612e6e656172222c22622e6e656172225d2c22657870697265735f6174223a6e756c6c7d7d0060b7986c88000001000000000000000000000000000000",
            hash: "85G3pYXaQLjMjGvCNKhkmYTMm1frq9Mu6CF5YSVEYF31"),
        "remove_pocket": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d00000072656d6f76655f706f636b6574110000007b226e616d65223a22636f66666565227d0060b7986c88000001000000000000000000000000000000",
            hash: "6RGjmG1RvH1HtUGPvzmzTE9j9iBgehf8BTGeFa3fxrqQ"),
        "pause_pocket": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020c00000070617573655f706f636b6574110000007b226e616d65223a22636f66666565227d0060b7986c88000001000000000000000000000000000000",
            hash: "4HERJKY6g1KXj6AyAzrK12hNVHGMmQWoWGq7HonYht9y"),
        "resume_pocket": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020d000000726573756d655f706f636b6574110000007b226e616d65223a22636f66666565227d0060b7986c88000001000000000000000000000000000000",
            hash: "FDvmjSpgNqNq8hKS4VY8X8a9ZuycCTBgYpBvxrNvxJi7"),
        "create_order": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020c0000006372656174655f6f726465729c0000007b22706f636b6574223a2272656e74222c22616d6f756e74223a22323030303030303030303030303030303030303030303030222c22726563697069656e74223a226c616e646c6f72642e6e656172222c22696e74657276616c5f7365636f6e6473223a3630343830302c2266697273745f6475655f6e73223a6e756c6c2c2272656d61696e696e67223a31322c226d656d6f223a2272656e74227d0060b7986c88000001000000000000000000000000000000",
            hash: "BR6oZEc2Ki27kW22WbvoaDcja7LukzhZcso431xoK4Rt"),
        "create_order_forever": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020c0000006372656174655f6f72646572820000007b22706f636b6574223a2272656e74222c22616d6f756e74223a2231222c22726563697069656e74223a226c616e646c6f72642e6e656172222c22696e74657276616c5f7365636f6e6473223a38363430302c2266697273745f6475655f6e73223a6e756c6c2c2272656d61696e696e67223a6e756c6c2c226d656d6f223a22227d0060b7986c88000001000000000000000000000000000000",
            hash: "HjrnUEdUF7pUcyv4TUgGbT84N2Ywagnx7z84NNoRUMMn"),
        "cancel_order": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020c00000063616e63656c5f6f726465720e0000007b226f726465725f6964223a327d0060b7986c88000001000000000000000000000000000000",
            hash: "5PGQU1N6UiyGqTidBGfTjmJADUXHZ2qp5WmjjK1EXLo4"),
        "approve": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c010000000207000000617070726f7665100000007b22726571756573745f6964223a377d0060b7986c88000001000000000000000000000000000000",
            hash: "H52D13yHX4WCViEWkoVouLgBKPPy7MhYP6VGs7uoUfej"),
        "reject": (hex: "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000001f0000006865726d69742d67756172642d313739343531303032332e746573746e6574394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000020600000072656a656374100000007b22726571756573745f6964223a377d0060b7986c88000001000000000000000000000000000000",
            hash: "7cpmZ6ute13Qox8nAuTtRsXn8fXBfSFfSEts6Eh4zLBk"),
    ]

    func check(_ name: String, _ receiver: String, _ actions: [NearAction], file: StaticString = #filePath, line: UInt = #line) {
        guard let v = Self.vectors[name] else { return XCTFail("no vector \(name)", file: file, line: line) }
        let t = tx(receiver, actions)
        XCTAssertEqual(t.serialized.hex, v.hex, name, file: file, line: line)
        XCTAssertEqual(t.hashString, v.hash, name, file: file, line: line)
    }

    func testAddKeyAndDeleteKeyMatchNearApiJs() {
        XCTAssertEqual(NearAccount.publicKeyString(pocketKey), pocketKeyText)
        check("add_key", implicit, [.addFunctionCallKey(publicKey: pocketKey, allowance: NearGuard.keyAllowance, receiver: guardID, methods: ["spend", "request"])])
        check("delete_key", implicit, [.deleteKey(publicKey: pocketKey)])
        // The layout by hand (nomicon: AddKey is tag 5, then the key, a nonce of 0 and a FunctionCall permission with Some(allowance)).
        var w = Borsh()
        w.u8(5); w.u8(0); w.fixed(pocketKey); w.u64(0); w.u8(0); w.u8(1); w.u128(NearGuard.keyAllowance); w.string(guardID); w.u32(2); w.string("spend"); w.string("request")
        var out = Borsh()
        NearAction.addFunctionCallKey(publicKey: pocketKey, allowance: NearGuard.keyAllowance, receiver: guardID, methods: ["spend", "request"]).encode(&out)
        XCTAssertEqual(out.bytes, w.bytes)
        var del = Borsh(); NearAction.deleteKey(publicKey: pocketKey).encode(&del)
        XCTAssertEqual(del.bytes, [6, 0] + pocketKey)
        // Key actions attach nothing and burn no contract gas.
        XCTAssertEqual(NearAction.deleteKey(publicKey: pocketKey).attached, 0)
        XCTAssertEqual(NearAction.deleteKey(publicKey: pocketKey).gas, 0)
    }

    func testGuardCallsMatchNearApiJs() {
        let storage = NearGuard.storageDeposit
        check("open_vault", guardID, [NearGuard.openVault(attaching: storage + near / 4)])
        check("deposit_near", guardID, [NearGuard.depositNear(3 * near / 2)])
        check("ft_transfer_call", usdc, [NearGuard.depositToken(guardContract: guardID, amount: 2_500_000)])
        check("withdraw_amount", guardID, [NearGuard.withdraw(token: "near", amount: 5 * near / 4)])
        check("withdraw_all", guardID, [NearGuard.withdraw(token: usdc, amount: nil)])
        check("close_vault", guardID, [NearGuard.closeVault])
        check("freeze", guardID, [NearGuard.freeze])
        check("unfreeze", guardID, [NearGuard.unfreeze])
        let coffee = NearGuard.PocketDraft(name: "coffee", token: "near", perPayment: near / 2, daily: near, recipients: [shop], expiresAtNs: 1_794_600_000_000_000_000)
        check("create_pocket_key", guardID, [NearGuard.createPocket(coffee, publicKey: pocketKeyText)])
        let rent = NearGuard.PocketDraft(name: "rent", token: usdc, perPayment: 50_000_000, daily: 50_000_000)
        check("create_pocket_nokey", guardID, [NearGuard.createPocket(rent, publicKey: nil)])
        let odd = NearGuard.PocketDraft(name: "Ke\"tt \u{e9}\\", token: "near", perPayment: 1, daily: 2)
        check("create_pocket_escaped", guardID, [NearGuard.createPocket(odd, publicKey: nil)])
        let update = NearGuard.PocketDraft(name: "coffee", token: "near", perPayment: near / 4, daily: 3 * near / 4, recipients: ["a.near", "b.near"], publicKey: pocketKeyText)
        check("update_pocket", guardID, [NearGuard.updatePocket(update)])
        check("remove_pocket", guardID, [NearGuard.removePocket("coffee")])
        check("pause_pocket", guardID, [NearGuard.pausePocket("coffee")])
        check("resume_pocket", guardID, [NearGuard.resumePocket("coffee")])
        check("create_order", guardID, [NearGuard.createOrder(.init(pocket: "rent", amount: near / 5, recipient: "landlord.near", intervalSeconds: 604_800, remaining: 12, memo: "rent"))])
        check("create_order_forever", guardID, [NearGuard.createOrder(.init(pocket: "rent", amount: 1, recipient: "landlord.near", intervalSeconds: 86_400))])
        check("cancel_order", guardID, [NearGuard.cancelOrder(2)])
        check("approve", guardID, [NearGuard.approve(7)])
        check("reject", guardID, [NearGuard.reject(7)])
    }

    // MARK: The contract's own source

    /// The Rust source in this checkout, or a skip when the test runs without contracts/.
    func contractSource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("contracts/guard/src/lib.rs")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("contracts/guard/src/lib.rs isn't in this checkout") }
        return s
    }

    func matches(_ pattern: String, in s: String) throws -> [[String]] {
        let re = try NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    func rustConst(_ name: String, in s: String) throws -> UInt128 {
        let m = try XCTUnwrap(try matches(#"const \#(name): u(?:\d+|size) = ([\d_]+);"#, in: s).first, name)
        return try XCTUnwrap(UInt128(m[1].replacingOccurrences(of: "_", with: "")), name)
    }

    /// Whether a JSON value is what serde would read as this Rust type.
    func conforms(_ v: JSON, _ rust: String, structs: [String: [(String, String)]]) -> Bool {
        let t = rust.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("Option<"), t.hasSuffix(">") {
            if v == .null { return true }
            return conforms(v, String(t.dropFirst(7).dropLast()), structs: structs)
        }
        if t.hasPrefix("Vec<"), t.hasSuffix(">") {
            guard let a = v.array else { return false }
            return a.allSatisfy { conforms($0, String(t.dropFirst(4).dropLast()), structs: structs) }
        }
        switch t {
        case "U128", "U64": return v.string.map { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) } ?? false
        case "u64", "u32": return v.double.map { $0 >= 0 && $0 == $0.rounded() } ?? false
        case "String", "AccountId", "PublicKey": return v.string != nil
        default:
            guard let fields = structs[t], case .object(let o) = v else { return false }
            return Set(o.keys) == Set(fields.map(\.0)) && fields.allSatisfy { f in o[f.0].map { conforms($0, f.1, structs: structs) } ?? false }
        }
    }

    func testArgumentsMatchTheContractSource() throws {
        let src = try contractSource()
        // PocketConfig's fields, as the contract declares them.
        let body = try XCTUnwrap(try matches(#"pub struct PocketConfig \{([^}]*)\}"#, in: src).first?[1])
        let config = try matches(#"pub (\w+): ([^,]+),"#, in: body).map { ($0[1], $0[2]) }
        XCTAssertEqual(config.map(\.0), ["name", "public_key", "token", "per_payment_cap", "daily_cap", "allowed_recipients", "expires_at"])
        let structs = ["PocketConfig": config]
        // Every method signature of the contract.
        var methods: [String: [(String, String)]] = [:]
        for m in try matches(#"pub fn (\w+)\(([^)]*)\)"#, in: src) {
            let params = m[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasSuffix("self") }
            methods[m[1]] = params.compactMap { p in
                let parts = p.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        }
        let draft = NearGuard.PocketDraft(name: "coffee", token: "near", perPayment: 5, daily: 9, recipients: [shop], expiresAtNs: 1_794_600_000_000_000_000, publicKey: pocketKeyText)
        let bare = NearGuard.PocketDraft(name: "rent", token: usdc, perPayment: 5, daily: 9)
        let order = NearGuard.OrderDraft(pocket: "rent", amount: 5, recipient: "landlord.near", intervalSeconds: 3600, remaining: 3, memo: "x")
        let calls: [NearAction] = [NearGuard.openVault(attaching: 1), NearGuard.depositNear(1), NearGuard.withdraw(token: "near", amount: 1), NearGuard.withdraw(token: "near", amount: nil),
                                   NearGuard.closeVault, NearGuard.freeze, NearGuard.unfreeze, NearGuard.createPocket(draft, publicKey: pocketKeyText),
                                   NearGuard.createPocket(bare, publicKey: nil), NearGuard.updatePocket(draft), NearGuard.removePocket("a"), NearGuard.pausePocket("a"),
                                   NearGuard.resumePocket("a"), NearGuard.createOrder(order), NearGuard.createOrder(.init(pocket: "rent", amount: 5, recipient: "a.near", intervalSeconds: 3600)),
                                   NearGuard.cancelOrder(1), NearGuard.approve(1), NearGuard.reject(1)]
        var seen = Set<String>()
        for case .functionCall(let method, let args, _, _) in calls {
            seen.insert(method)
            let sig = try XCTUnwrap(methods[method], "\(method) isn't a method of the contract")
            let j = try JSONDecoder().decode(JSON.self, from: Data(args))
            guard case .object(let o) = j else { return XCTFail("\(method): arguments aren't an object") }
            XCTAssertEqual(Set(o.keys), Set(sig.map(\.0)), method)
            for (name, type) in sig {
                XCTAssertTrue(o[name].map { conforms($0, type, structs: structs) } ?? false, "\(method).\(name) is not a \(type): \(String(describing: o[name]))")
            }
        }
        XCTAssertEqual(seen.count, 15)   // every owner call the app makes
        // ft_transfer_call is the token's, not the contract's: NEP-141's own names. The amount is a string, msg is empty.
        guard case .functionCall(let m, let a, let gas, let deposit) = NearGuard.depositToken(guardContract: guardID, amount: 7) else { return XCTFail() }
        XCTAssertEqual(m, "ft_transfer_call"); XCTAssertEqual(deposit, 1); XCTAssertEqual(gas, 200 * NearAction.tgas)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: Data(a)), ["receiver_id": .string(guardID), "amount": "7", "msg": ""])
        // The numbers the contract fixes.
        XCTAssertEqual(try rustConst("STORAGE_DEPOSIT", in: src), NearGuard.storageDeposit)
        XCTAssertEqual(try rustConst("MAX_POCKETS", in: src), UInt128(NearGuard.maxPockets))
        XCTAssertEqual(try rustConst("MAX_ORDERS", in: src), UInt128(NearGuard.maxOrders))
        XCTAssertEqual(try rustConst("MAX_RECIPIENTS", in: src), UInt128(NearGuard.maxRecipients))
        XCTAssertEqual(try rustConst("MAX_RECEIPTS", in: src), UInt128(NearGuard.maxReceipts))
        XCTAssertEqual(try rustConst("MAX_NAME_BYTES", in: src), UInt128(NearGuard.maxNameBytes))
        XCTAssertEqual(try rustConst("MAX_TEXT_BYTES", in: src), UInt128(NearGuard.maxTextBytes))
        XCTAssertEqual(try rustConst("MIN_INTERVAL_SECONDS", in: src), UInt128(NearGuard.minIntervalSeconds))
        XCTAssertEqual(try rustConst("MAX_INTERVAL_SECONDS", in: src), UInt128(NearGuard.maxIntervalSeconds))
        XCTAssertEqual(try rustConst("DAY_NS", in: src), UInt128(NearGuard.dayNs))
        // Gas: every call carries more than the contract's floor for payouts (120 TGas in the code).
        let floor = try rustConst("MIN_GAS_FOR_PAYOUT", in: src)
        XCTAssertGreaterThanOrEqual(UInt128(NearGuard.gas), floor)
        XCTAssertGreaterThanOrEqual(UInt128(NearGuard.tokenDepositGas), floor)
        // The contract asks for exactly one yocto on these (assert_one_yocto in owner_entry): the app attaches exactly that.
        let ownerOnly = ["withdraw", "close_vault", "freeze", "unfreeze", "create_pocket", "update_pocket", "remove_pocket", "pause_pocket",
                         "resume_pocket", "create_order", "cancel_order", "approve", "reject"]
        for case .functionCall(let method, _, let gas, let deposit) in calls where ownerOnly.contains(method) {
            XCTAssertEqual(deposit, 1, method); XCTAssertEqual(gas, NearGuard.gas, method)
        }
    }

    func testAmountsAndGas() {
        XCTAssertEqual(NearGuard.gas, 150_000_000_000_000)
        XCTAssertEqual(NearGuard.tokenDepositGas, 200_000_000_000_000)
        XCTAssertEqual(NearGuard.oneYocto, 1)
        XCTAssertEqual(NearGuard.feeCeiling, 3 * near / 100)           // 150 TGas at twice mainnet's gas price
        XCTAssertEqual(NearGuard.tokenDepositFeeCeiling, 4 * near / 100)
        XCTAssertEqual(NearGuard.keyAllowance, near / 4)
        XCTAssertEqual(NearGuard.keyMethods, ["spend", "request"])
        XCTAssertEqual(NearGuard.maxDeposit(available: 10 * near), 10 * near - near / 20 - 3 * near / 100)
        XCTAssertEqual(NearGuard.maxDeposit(available: near / 20), 0)
        // open_vault attaches the storage deposit plus the first deposit; deposit_near attaches the amount; nothing else attaches more than 1.
        XCTAssertEqual(NearGuard.openVault(attaching: 3 * near / 4).attached, 3 * near / 4)
        XCTAssertEqual(NearGuard.depositNear(7).attached, 7)
        for a in [NearGuard.freeze, NearGuard.unfreeze, NearGuard.closeVault, NearGuard.approve(1), NearGuard.reject(1), NearGuard.cancelOrder(1),
                  NearGuard.withdraw(token: "near", amount: nil), NearGuard.removePocket("a"), NearGuard.pausePocket("a"), NearGuard.resumePocket("a")] {
            XCTAssertEqual(a.attached, 1)
            XCTAssertEqual(a.gas, 150 * NearAction.tgas)
        }
    }

    // MARK: Hidden until there is a contract

    func testHiddenWithoutAContract() {
        XCTAssertNil(GuardConfig.resolve(mainnet: nil, override: nil, allowOverride: true))
        XCTAssertNil(GuardConfig.resolve(mainnet: nil, override: nil, allowOverride: false))
        // The override is for debug builds: with it switched off a testnet id changes nothing.
        XCTAssertNil(GuardConfig.resolve(mainnet: nil, override: guardID, allowOverride: false))
        XCTAssertEqual(GuardConfig.resolve(mainnet: nil, override: " \(guardID) ", allowOverride: true), guardID)
        XCTAssertNil(GuardConfig.resolve(mainnet: nil, override: "Not A Name", allowOverride: true))
        XCTAssertEqual(GuardConfig.resolve(mainnet: "guard.near", override: nil, allowOverride: true), "guard.near")
        XCTAssertEqual(GuardConfig.resolve(mainnet: "guard.near", override: "x.testnet", allowOverride: false), "guard.near")
        // A testnet account is never taken for the mainnet contract.
        XCTAssertNil(GuardConfig.resolve(mainnet: guardID, override: nil, allowOverride: false))
        // Until the mainnet id is pasted in, a release build has no Budgets anywhere.
        if GuardConfig.mainnetContractID == nil { XCTAssertNil(GuardConfig.resolve(mainnet: GuardConfig.mainnetContractID, override: nil, allowOverride: false)) }
        XCTAssertEqual(GuardConfig.isEnabled, GuardConfig.contractID != nil)
        XCTAssertEqual(GuardConfig.expectedCodeHash(for: guardID), GuardConfig.testnetCodeHash)
    }

    func testReviewRefusesAnotherContract() throws {
        let s = try snapshot()
        var c = context(s)
        c.configured = nil
        XCTAssertTrue(blocked(.depositNear(near), c).contains("isn't the Budgets contract"))
        c.configured = "someone-else.near"
        XCTAssertTrue(blocked(.setFrozen(true), c).contains("isn't the Budgets contract"))
        // Even a withdrawal: the contract id has to be the one Hermit is configured for.
        XCTAssertTrue(blocked(.withdraw(token: "near", amount: nil), c).contains("isn't the Budgets contract"))
    }

    // MARK: Reading the contract (real testnet answers)

    func testViewsDecodeFromTestnetAnswers() throws {
        let vault = try XCTUnwrap(try NearGuard.decode(NearGuard.GuardVault?.self, from: view("near-guard-get-vault")))
        XCTAssertEqual(vault.owner, owner); XCTAssertFalse(vault.frozen)
        XCTAssertEqual(vault.balances, [.init(token: "near", amount: 300_000_000_000_000_000_000_000), .init(token: gtt, amount: 900)])
        XCTAssertEqual(vault.balance("near"), near * 3 / 10); XCTAssertEqual(vault.balance(gtt), 900); XCTAssertEqual(vault.balance("nope.near"), 0)
        XCTAssertEqual(vault.pockets, 3); XCTAssertEqual(vault.orders, 1); XCTAssertEqual(vault.requests, 0)
        XCTAssertEqual(vault.receiptsTotal, 9); XCTAssertEqual(vault.pendingOut, 0); XCTAssertEqual(vault.storagePaid, NearGuard.storageDeposit)
        // No vault is `null`.
        XCTAssertNil(try NearGuard.decode(NearGuard.GuardVault?.self, from: view("near-guard-get-vault-none")))

        let pockets = try NearGuard.decode([NearGuard.GuardPocket].self, from: view("near-guard-get-pockets"))
        XCTAssertEqual(pockets.map(\.name), ["coffee", "tokens", "rent"])
        let coffee = pockets[0]
        XCTAssertEqual(coffee.publicKey, "ed25519:FvqUv6FonvqGuNdXpxnV2mFcSigpHgf7FxTfYU1PSM9T")
        XCTAssertEqual(coffee.token, "near"); XCTAssertEqual(coffee.perPaymentCap, near / 2); XCTAssertEqual(coffee.dailyCap, near)
        XCTAssertEqual(coffee.spent, near * 9 / 10); XCTAssertEqual(coffee.windowStart, 1_794_510_340_735_420_147)
        XCTAssertEqual(coffee.allowedRecipients, [shop]); XCTAssertNil(coffee.expiresAt); XCTAssertFalse(coffee.paused)
        XCTAssertEqual(pockets[1].token, gtt); XCTAssertEqual(pockets[1].perPaymentCap, 100); XCTAssertEqual(pockets[1].dailyCap, 250)
        XCTAssertEqual(pockets[1].allowedRecipients.count, 2)
        XCTAssertNil(pockets[2].publicKey)                              // a pocket for standing orders only
        // The day is a fixed 24 hours from the first payment: 0.9 of 1 NEAR is spent while it is open, nothing once it has ended.
        XCTAssertEqual(coffee.spentToday(nowNs: now), near * 9 / 10); XCTAssertEqual(coffee.leftToday(nowNs: now), near / 10)
        XCTAssertEqual(coffee.spentToday(nowNs: coffee.windowStart + NearGuard.dayNs), 0)
        XCTAssertEqual(coffee.spentToday(nowNs: coffee.windowStart + NearGuard.dayNs - 1), near * 9 / 10)
        XCTAssertEqual(coffee.leftToday(nowNs: coffee.windowStart + 2 * NearGuard.dayNs), near)
        XCTAssertEqual(coffee.state(nowNs: now), .active)
        let paused = NearGuard.GuardPocket(name: "p", publicKey: nil, token: "near", perPaymentCap: 1, dailyCap: 1, spent: 0, windowStart: 0, allowedRecipients: [], expiresAt: now - 1, paused: false)
        XCTAssertEqual(paused.state(nowNs: now), .expired); XCTAssertEqual(paused.spentToday(nowNs: now), 0)

        let orders = try NearGuard.decode([NearGuard.GuardOrder].self, from: view("near-guard-get-orders"))
        XCTAssertEqual(orders, [.init(id: 2, pocket: "rent", token: "near", amount: near / 5, recipient: shop, intervalSeconds: 3600,
                                      nextDueNs: 1_794_514_280_615_436_032, remaining: 1, memo: "rent")])
        XCTAssertEqual(try NearGuard.decode([NearGuard.GuardRequest].self, from: view("near-guard-get-requests")), [])

        let receipts = try NearGuard.decode([NearGuard.GuardReceipt].self, from: view("near-guard-get-receipts"))
        XCTAssertEqual(receipts.map(\.id), Array(0...8))                     // the contract lists oldest first
        XCTAssertEqual(NearGuard.newestFirst(receipts).map(\.id), Array((0...8).reversed()))
        XCTAssertEqual(receipts.map(\.kind), [.spend, .spend, .spend, .spend, .approved, .withdraw, .order, .order, .spend])
        XCTAssertEqual(receipts[3].ok, false); XCTAssertEqual(receipts[3].reason, "will bounce"); XCTAssertEqual(receipts[3].token, gtt)
        XCTAssertEqual(receipts.filter { !$0.ok }.count, 1)
        XCTAssertEqual(receipts[4].amount, 3 * near / 2); XCTAssertEqual(receipts[5].pocket, ""); XCTAssertEqual(receipts[5].recipient, owner)
        XCTAssertEqual(receipts[0].timeNs, 1_794_510_340_735_420_147)

        XCTAssertEqual(try NearGuard.decode([String].self, from: view("near-guard-get-tokens")), ["near", gtt])
        XCTAssertEqual(try NearGuard.decodeAmount(view("near-guard-storage-cost")), NearGuard.storageDeposit)
        // A token's name and decimals, as Hermit reads them for a token it has no table entry for.
        let meta = NearClient.viewValue(try XCTUnwrap(try rpc("near-guard-ft-metadata")["result"]))
        XCTAssertEqual(meta["symbol"]?.string, "GTT"); XCTAssertEqual(meta["decimals"]?.int, 6)
    }

    func testModelsRoundTrip() throws {
        let pockets = try NearGuard.decode([NearGuard.GuardPocket].self, from: view("near-guard-get-pockets"))
        XCTAssertEqual(try NearGuard.decode([NearGuard.GuardPocket].self, from: JSONEncoder().encode(pockets)), pockets)
        let receipts = try NearGuard.decode([NearGuard.GuardReceipt].self, from: view("near-guard-get-receipts"))
        XCTAssertEqual(try NearGuard.decode([NearGuard.GuardReceipt].self, from: JSONEncoder().encode(receipts)), receipts)
        let orders = try NearGuard.decode([NearGuard.GuardOrder].self, from: view("near-guard-get-orders"))
        XCTAssertEqual(try NearGuard.decode([NearGuard.GuardOrder].self, from: JSONEncoder().encode(orders)), orders)
        // A kind the app doesn't know yet doesn't break the list.
        let odd = Data(#"[{"id":1,"time":"5","pocket":"","token":"near","amount":"1","recipient":"a.near","reason":"","kind":"refund","ok":true}]"#.utf8)
        XCTAssertEqual(try NearGuard.decode([NearGuard.GuardReceipt].self, from: odd).first?.kind, .other("refund"))
        XCTAssertThrowsError(try NearGuard.decode([NearGuard.GuardOrder].self, from: Data(#"[{"id":1}]"#.utf8)))
        XCTAssertThrowsError(try NearGuard.decodeAmount(Data(#""12x""#.utf8)))
    }

    func testFailureTextFromTheRefusedTransaction() throws {
        // The real status of testnet tx 9fQjv5HS6r...: a pocket key over its per-payment cap.
        let failure = try XCTUnwrap(try rpc("near-guard-tx-refused")["result"]?["status"]?["Failure"])
        let raw = String(data: try JSONEncoder().encode(failure), encoding: .utf8) ?? ""
        XCTAssertEqual(NearGuard.failureText(raw), "over per-payment cap")
        // The contract's own words for the things an owner can run into, in the same shape.
        func panic(_ m: String) -> String { #"{"ActionError":{"index":0,"kind":{"FunctionCallError":{"ExecutionError":"Smart contract panicked: \#(m)"}}}}"# }
        XCTAssertEqual(NearGuard.failureText(panic("pocket name already used")), "You already have a pocket with that name.")
        XCTAssertEqual(NearGuard.failureText(panic("vault frozen")), "Budgets is frozen.")
        XCTAssertEqual(NearGuard.failureText("plain text"), "plain text")
    }

    // MARK: Words

    func testWordsAndAmounts() {
        XCTAssertEqual(NearGuard.everyText(3_600), "every hour"); XCTAssertEqual(NearGuard.everyText(7_200), "every 2 hours")
        XCTAssertEqual(NearGuard.everyText(86_400), "every day"); XCTAssertEqual(NearGuard.everyText(172_800), "every 2 days")
        XCTAssertEqual(NearGuard.everyText(604_800), "every week"); XCTAssertEqual(NearGuard.everyText(1_209_600), "every 2 weeks")
        XCTAssertEqual(NearGuard.everyText(90), "every 90 seconds")
        let n = NearGuard.TokenInfo.near
        XCTAssertEqual(n.text(near / 2), "0.5 NEAR"); XCTAssertEqual(n.number(1), "<0.00001"); XCTAssertEqual(n.number(0), "0")
        XCTAssertEqual(n.number(near + 123_456_789_000_000_000_000_000), "1.12345")      // cut, never rounded up
        let usdcInfo = NearGuard.knownToken(usdc)
        XCTAssertEqual(usdcInfo, .init(id: usdc, symbol: "USDC", decimals: 6))
        XCTAssertEqual(usdcInfo?.text(2_500_000), "2.5 USDC"); XCTAssertEqual(usdcInfo?.text(1), "0.000001 USDC")
        XCTAssertNil(NearGuard.knownToken(gtt)); XCTAssertEqual(NearGuard.knownToken("near"), .near)
        XCTAssertEqual(NearGuard.parseRecipients("Shop.NEAR, bob.near\nshop.near;  carol.near"), ["shop.near", "bob.near", "carol.near"])
        XCTAssertEqual(NearGuard.parseRecipients("  "), [])
    }

    // MARK: What the owner types

    func testPocketAndOrderValidation() throws {
        let tokens = [NearGuard.TokenInfo.near, .init(id: gtt, symbol: "GTT", decimals: 6)]
        func bad(_ d: NearGuard.PocketDraft) -> String {
            do { try NearGuard.validate(d, tokens: tokens, contract: guardID, nowNs: now); XCTFail("accepted \(d)"); return "" }
            catch WalletError.blocked(let m) { return m } catch { XCTFail("\(error)"); return "" }
        }
        let ok = NearGuard.PocketDraft(name: "coffee", token: "near", perPayment: 5, daily: 5)
        XCTAssertNoThrow(try NearGuard.validate(ok, tokens: tokens, contract: guardID, nowNs: now))
        var d = ok; d.name = ""; XCTAssertTrue(bad(d).contains("1 to 24"))
        d = ok; d.name = String(repeating: "a", count: 25); XCTAssertTrue(bad(d).contains("1 to 24"))
        d = ok; d.name = String(repeating: "\u{e9}", count: 13); XCTAssertTrue(bad(d).contains("1 to 24"))   // 26 bytes
        d = ok; d.name = "a\nb"; XCTAssertTrue(bad(d).contains("line breaks"))
        d = ok; d.name = " lead"; XCTAssertTrue(bad(d).contains("space"))
        d = ok; d.token = "other.near"; XCTAssertTrue(bad(d).contains("doesn't take that token"))
        d = ok; d.perPayment = 0; XCTAssertTrue(bad(d).contains("more than 0"))
        d = ok; d.daily = 4; XCTAssertTrue(bad(d).contains("daily limit can't be lower"))
        d = ok; d.recipients = ["Not Valid"]; XCTAssertTrue(bad(d).contains("isn't a NEAR account"))
        d = ok; d.recipients = [guardID]; XCTAssertTrue(bad(d).contains("itself"))
        d = ok; d.recipients = (0..<21).map { "r\($0).near" }; XCTAssertTrue(bad(d).contains("at most 20"))
        d = ok; d.expiresAtNs = now; XCTAssertTrue(bad(d).contains("in the future"))
        d = ok; d.expiresAtNs = now + 1; XCTAssertNoThrow(try NearGuard.validate(d, tokens: tokens, contract: guardID, nowNs: now))

        let pocket = NearGuard.GuardPocket(name: "rent", publicKey: nil, token: "near", perPaymentCap: near, dailyCap: 2 * near, spent: 0, windowStart: 0,
                                           allowedRecipients: [shop], expiresAt: nil, paused: false)
        func badOrder(_ o: NearGuard.OrderDraft) -> String {
            do { try NearGuard.validate(o, pocket: pocket, contract: guardID); XCTFail("accepted \(o)"); return "" }
            catch WalletError.blocked(let m) { return m } catch { XCTFail("\(error)"); return "" }
        }
        let order = NearGuard.OrderDraft(pocket: "rent", amount: near, recipient: shop, intervalSeconds: 3_600, remaining: 1, memo: "x")
        XCTAssertNoThrow(try NearGuard.validate(order, pocket: pocket, contract: guardID))
        var o = order; o.amount = near + 1; XCTAssertTrue(badOrder(o).contains("within the pocket's limit"))
        o = order; o.amount = 0; XCTAssertTrue(badOrder(o).contains("more than 0"))
        o = order; o.recipient = "other.near"; XCTAssertTrue(badOrder(o).contains("doesn't allow payments to other.near"))
        o = order; o.intervalSeconds = 3_599; XCTAssertTrue(badOrder(o).contains("every hour"))
        o = order; o.intervalSeconds = 315_360_001; XCTAssertTrue(badOrder(o).contains("10 years"))
        o = order; o.remaining = 0; XCTAssertTrue(badOrder(o).contains("at least once"))
        o = order; o.memo = String(repeating: "m", count: 141); XCTAssertTrue(badOrder(o).contains("too long"))
    }

    // MARK: Plans: which transactions, in which order

    func testPocketWithKeyIsAddKeyThenCreatePocketWithRollback() throws {
        let d = NearGuard.PocketDraft(name: "agent", token: "near", perPayment: near / 2, daily: near, recipients: [shop], withKey: true)
        let plan = try NearGuard.plan(.createPocket(d), contract: guardID, account: implicit, newPocketKey: pocketKey)
        XCTAssertEqual(plan.steps.count, 2)
        // 1. The key goes on the owner's own account, limited to the contract and the two methods, with the 0.25 NEAR gas budget.
        XCTAssertEqual(plan.steps[0], .init(receiver: implicit, actions: [.addFunctionCallKey(publicKey: pocketKey, allowance: near / 4, receiver: guardID, methods: ["spend", "request"])]))
        // 2. Only then the contract is told about it.
        XCTAssertEqual(plan.steps[1], .init(receiver: guardID, actions: [NearGuard.createPocket(d, publicKey: pocketKeyText)]))
        // If 2 is refused the key is taken off the account again (signed in the same unlock, sent only on that failure).
        XCTAssertEqual(plan.rollback, .init(receiver: implicit, actions: [.deleteKey(publicKey: pocketKey)]))
        // A function-call key is the only kind of key the app can add.
        for step in plan.steps { for case .addFunctionCallKey(_, _, let receiver, let methods) in step.actions { XCTAssertEqual(receiver, guardID); XCTAssertEqual(methods, NearGuard.keyMethods) } }
        // No key made: a missing or short key is refused rather than sent without one.
        XCTAssertThrowsError(try NearGuard.plan(.createPocket(d), contract: guardID, account: implicit, newPocketKey: nil))
        XCTAssertThrowsError(try NearGuard.plan(.createPocket(d), contract: guardID, account: implicit, newPocketKey: [1, 2, 3]))
        // Without a key it is one transaction and nothing to roll back.
        var bare = d; bare.withKey = false
        let single = try NearGuard.plan(.createPocket(bare), contract: guardID, account: implicit)
        XCTAssertEqual(single.steps, [.init(receiver: guardID, actions: [NearGuard.createPocket(bare, publicKey: nil)])]); XCTAssertNil(single.rollback)
    }

    func testRemovingAPocketStopsItBeforeDeletingItsKey() throws {
        let key = "ed25519:FvqUv6FonvqGuNdXpxnV2mFcSigpHgf7FxTfYU1PSM9T"
        let plan = try NearGuard.plan(.removePocket(name: "coffee"), contract: guardID, account: implicit, deleteKey: key)
        XCTAssertEqual(plan.steps.map(\.receiver), [guardID, implicit])
        XCTAssertEqual(plan.steps[0].actions, [NearGuard.removePocket("coffee")])
        XCTAssertEqual(plan.steps[1].actions, [.deleteKey(publicKey: try XCTUnwrap(Base58.decode("FvqUv6FonvqGuNdXpxnV2mFcSigpHgf7FxTfYU1PSM9T")))])
        XCTAssertNil(plan.rollback)
        XCTAssertEqual(try NearGuard.plan(.removePocket(name: "coffee"), contract: guardID, account: implicit).steps.count, 1)
        XCTAssertThrowsError(try NearGuard.plan(.removePocket(name: "coffee"), contract: guardID, account: implicit, deleteKey: "secp256k1:abc"))
        // The other moves are one transaction each, to the right place.
        XCTAssertEqual(try NearGuard.plan(.depositToken(token: usdc, amount: 5), contract: guardID, account: implicit).steps.map(\.receiver), [usdc])
        XCTAssertEqual(try NearGuard.plan(.openVault(storage: NearGuard.storageDeposit, initial: near), contract: guardID, account: implicit).steps[0].actions,
                       [NearGuard.openVault(attaching: 3 * near / 2)])
        XCTAssertEqual(try NearGuard.plan(.setFrozen(true), contract: guardID, account: implicit).steps[0].actions, [NearGuard.freeze])
        XCTAssertEqual(try NearGuard.plan(.setPaused(name: "a", paused: false), contract: guardID, account: implicit).steps[0].actions, [NearGuard.resumePocket("a")])
    }

    func testOnlyAKeyHermitMadeIsEverDeleted() {
        let mine = NearGuard.KeyPermission.functionCall(receiver: guardID, methods: ["spend", "request"])
        XCTAssertTrue(NearGuard.isHermitPocketKey(mine, contract: guardID))
        XCTAssertTrue(NearGuard.isHermitPocketKey(.functionCall(receiver: guardID, methods: ["spend"]), contract: guardID))
        // A full-access key (the owner's own, named by a pocket made from the command line) must never be deleted.
        XCTAssertFalse(NearGuard.isHermitPocketKey(.fullAccess, contract: guardID))
        XCTAssertFalse(NearGuard.isHermitPocketKey(.functionCall(receiver: "other.near", methods: ["spend"]), contract: guardID))
        XCTAssertFalse(NearGuard.isHermitPocketKey(.functionCall(receiver: guardID, methods: ["spend", "withdraw"]), contract: guardID))
        XCTAssertFalse(NearGuard.isHermitPocketKey(.functionCall(receiver: guardID, methods: []), contract: guardID))
        // As view_access_key words it.
        XCTAssertEqual(NearGuard.KeyPermission("FullAccess"), .fullAccess)
        XCTAssertEqual(NearGuard.KeyPermission(["FunctionCall": ["allowance": "250000000000000000000000", "receiver_id": .string(guardID), "method_names": ["spend", "request"]]]), mine)
        XCTAssertNil(NearGuard.KeyPermission(["Other": 1]))
    }

    // MARK: A key shown once

    func testIssuedKeyFormats() throws {
        let seed = [UInt8](repeating: 7, count: 32)
        let pub = [UInt8](try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation)
        let k = IssuedKey(account: implicit, pocket: "agent", seed: seed, publicKey: pub)
        XCTAssertEqual(k.publicKey, NearAccount.publicKeyString(pub))
        XCTAssertTrue(k.privateKey.hasPrefix("ed25519:"))
        XCTAssertEqual(Base58.decode(String(k.privateKey.dropFirst(8))), seed + pub)         // near-cli's 64 bytes: seed, then public key
        let file = try JSONDecoder().decode(JSON.self, from: Data(k.keyFile.utf8))
        XCTAssertEqual(file["account_id"]?.string, implicit); XCTAssertEqual(file["public_key"]?.string, k.publicKey); XCTAssertEqual(file["private_key"]?.string, k.privateKey)
        // Printing one never shows the secret.
        XCTAssertFalse("\(k)".contains(k.privateKey)); XCTAssertFalse(String(reflecting: k).contains(k.privateKey))
        XCTAssertTrue("\(k)".contains("agent"))
    }

    // MARK: Reviews

    func snapshot(vault: NearGuard.GuardVault?? = nil, pockets: [NearGuard.GuardPocket]? = nil, orders: [NearGuard.GuardOrder]? = nil,
                  requests: [NearGuard.GuardRequest] = []) throws -> NearGuard.Snapshot {
        let tokens = [NearGuard.TokenInfo.near, .init(id: gtt, symbol: "GTT", decimals: 6)]
        let v: NearGuard.GuardVault? = try vault ?? NearGuard.decode(NearGuard.GuardVault?.self, from: view("near-guard-get-vault"))
        return .init(contract: guardID, vault: v, pockets: try pockets ?? NearGuard.decode([NearGuard.GuardPocket].self, from: view("near-guard-get-pockets")),
                     orders: try orders ?? NearGuard.decode([NearGuard.GuardOrder].self, from: view("near-guard-get-orders")), requests: requests,
                     receipts: [], tokens: tokens, storageCost: NearGuard.storageDeposit)
    }

    func vault(_ balances: [NearGuard.GuardBalance], frozen: Bool = false, pockets: Int = 0, pendingOut: Int = 0) -> NearGuard.GuardVault {
        .init(owner: owner, frozen: frozen, balances: balances, pockets: pockets, orders: 0, requests: 0, receiptsTotal: 0, pendingOut: pendingOut, storagePaid: NearGuard.storageDeposit)
    }

    /// A healthy contract (the code Hermit checked) and an account with 10 NEAR in it.
    func context(_ s: NearGuard.Snapshot, available: UInt128? = 10_000_000_000_000_000_000_000_000) -> NearGuard.Context {
        var c = NearGuard.Context(contract: guardID, configured: guardID, snapshot: s, available: available, nowNs: now)
        c.codeHash = GuardConfig.testnetCodeHash; c.accessKeys = 1
        return c
    }

    func review(_ move: NearGuard.Move, _ c: NearGuard.Context, origin: ActionOrigin = .user) throws -> NearGuard.Review {
        try NearGuard.review(move, walletID: wallet, account: implicit, context: c, policy: policy(), origin: origin)
    }

    func blocked(_ move: NearGuard.Move, _ c: NearGuard.Context, file: StaticString = #filePath, line: UInt = #line) -> String {
        do { _ = try review(move, c); XCTFail("expected a block", file: file, line: line); return "" }
        catch WalletError.blocked(let why) { return why } catch { XCTFail("unexpected \(error)", file: file, line: line); return "" }
    }

    func testCreatePocketWithKeyReview() throws {
        let c = context(try snapshot())
        let d = NearGuard.PocketDraft(name: "agent", token: "near", perPayment: near / 2, daily: near, recipients: [shop], withKey: true)
        let r = try review(.createPocket(d), c)
        XCTAssertTrue(r.issuesKey); XCTAssertNil(r.deleteKey); XCTAssertEqual(r.contract, guardID)
        XCTAssertEqual(r.title, "Create pocket agent")
        XCTAssertTrue(r.warnings.contains("The pocket agent can pay up to 0.5 NEAR per payment and 1 NEAR per day without asking you."))
        XCTAssertTrue(r.lines.contains(["Per payment", "Up to 0.5 NEAR"])); XCTAssertTrue(r.lines.contains(["Per day", "Up to 1 NEAR"]))
        XCTAssertTrue(r.lines.contains(["Can pay", shop])); XCTAssertTrue(r.lines.contains(["The key can", "Only call spend and request on \(guardID)"]))
        XCTAssertTrue(r.checks.contains("If the pocket can't be created, Hermit removes the key again"))
        XCTAssertTrue(r.warnings.contains { $0.contains("twice the daily limit") })
        // Anyone: said plainly.
        var any = d; any.recipients = []
        XCTAssertTrue(try review(.createPocket(any), c).warnings.contains { $0.contains("any address") })
        // Without a key nothing is made.
        var bare = d; bare.withKey = false
        let b = try review(.createPocket(bare), c)
        XCTAssertFalse(b.issuesKey); XCTAssertTrue(b.lines.contains { $0[0] == "Key" && $0[1].hasPrefix("None") })
    }

    func testCreatePocketRefusals() throws {
        let s = try snapshot()
        let d = NearGuard.PocketDraft(name: "agent", token: "near", perPayment: near / 2, daily: near, withKey: true)
        var dup = d; dup.name = "coffee"
        XCTAssertTrue(blocked(.createPocket(dup), context(s)).contains("already have a pocket called coffee"))
        XCTAssertTrue(blocked(.createPocket(d), context(try snapshot(vault: .some(nil)))).contains("Set up Budgets first"))
        let eight = (0..<8).map { NearGuard.GuardPocket(name: "p\($0)", publicKey: nil, token: "near", perPaymentCap: 1, dailyCap: 1, spent: 0, windowStart: 0, allowedRecipients: [], expiresAt: nil, paused: false) }
        XCTAssertTrue(blocked(.createPocket(d), context(try snapshot(pockets: eight))).contains("8 pockets"))
        // A key needs room for two fees and the key's storage on top of the reserve.
        XCTAssertTrue(blocked(.createPocket(d), context(s, available: near / 10)).contains("Not enough NEAR"))
        XCTAssertTrue(blocked(.createPocket(d), context(s, available: nil)).contains("isn't active yet"))
        var gtt2 = d; gtt2.token = "unlisted.near"
        XCTAssertTrue(blocked(.createPocket(gtt2), context(s)).contains("doesn't take that token"))
    }

    func testUpdatePocketKeepsItsKey() throws {
        let s = try snapshot()
        let old = try XCTUnwrap(s.pocket("coffee"))
        let d = NearGuard.PocketDraft(name: "coffee", token: "near", perPayment: near / 4, daily: near / 2, recipients: [shop], publicKey: old.publicKey)
        let r = try review(.updatePocket(d), context(s))
        XCTAssertTrue(r.lines.contains(["Per payment", "Up to 0.5 NEAR to Up to 0.25 NEAR"]))
        XCTAssertEqual(NearGuard.updatePocket(d), try XCTUnwrap(try NearGuard.plan(.updatePocket(d), contract: guardID, account: implicit).steps.first?.actions.first))
        guard case .functionCall(_, let args, _, _) = NearGuard.updatePocket(d) else { return XCTFail() }
        XCTAssertTrue(String(decoding: args, as: UTF8.self).contains(#""public_key":"ed25519:FvqUv6FonvqGuNdXpxnV2mFcSigpHgf7FxTfYU1PSM9T""#))
        // Raising limits is called out; dropping the key by leaving it out is refused.
        var up = d; up.perPayment = near; up.daily = 2 * near
        XCTAssertTrue(try review(.updatePocket(up), context(s)).warnings.contains("This raises what the pocket can pay."))
        var nokey = d; nokey.publicKey = nil
        XCTAssertTrue(blocked(.updatePocket(nokey), context(s)).contains("key can't be changed"))
        var other = d; other.token = gtt
        XCTAssertTrue(blocked(.updatePocket(other), context(s)).contains("token can't be changed"))
        var ghost = d; ghost.name = "ghost"
        XCTAssertTrue(blocked(.updatePocket(ghost), context(s)).contains("no pocket called ghost"))
    }

    func testRemovePocketReviewDecidesAboutTheKey() throws {
        let s = try snapshot()
        let key = try XCTUnwrap(s.pocket("coffee")?.publicKey)
        var c = context(s)
        // The key is a function-call key for this contract: it goes with the pocket.
        c.pocketKeyRead = true; c.pocketKeyPermission = .functionCall(receiver: guardID, methods: ["spend", "request"])
        let r = try review(.removePocket(name: "coffee"), c)
        XCTAssertEqual(r.deleteKey, key); XCTAssertTrue(r.lines.contains(["Key", "Deleted from your account"]))
        // The key is something else on the account: it stays, and the review says so.
        c.pocketKeyPermission = .fullAccess
        let keep = try review(.removePocket(name: "coffee"), c)
        XCTAssertNil(keep.deleteKey); XCTAssertTrue(keep.warnings.contains { $0.contains("didn't make") })
        // The key is already gone from the account.
        c.pocketKeyPermission = nil
        let gone = try review(.removePocket(name: "coffee"), c)
        XCTAssertNil(gone.deleteKey); XCTAssertTrue(gone.lines.contains(["Key", "Already gone from your account"]))
        // The key couldn't be looked up: nothing is prepared on a guess.
        c.pocketKeyRead = false
        XCTAssertTrue(blocked(.removePocket(name: "coffee"), c).contains("Couldn't check this pocket's key"))
        // A pocket without a key has none to delete; its orders are named.
        let rent = try review(.removePocket(name: "rent"), context(s))
        XCTAssertNil(rent.deleteKey); XCTAssertTrue(rent.lines.contains(["Standing orders deleted", "1"]))
        // The owner's own key, named by a pocket that was made by hand, is never deleted even if it looks like a pocket key.
        let own = NearAccount.publicKeyString([UInt8](hex: implicit)!)
        let hand = NearGuard.GuardPocket(name: "hand", publicKey: own, token: "near", perPaymentCap: 1, dailyCap: 1, spent: 0, windowStart: 0, allowedRecipients: [], expiresAt: nil, paused: false)
        var ch = context(try snapshot(pockets: [hand]))
        ch.pocketKeyRead = true; ch.pocketKeyPermission = .functionCall(receiver: guardID, methods: ["spend"])
        XCTAssertNil(try review(.removePocket(name: "hand"), ch).deleteKey)
    }

    func testDepositsNeedTheTokenSetUpOnBothSides() throws {
        let s = try snapshot()
        var c = context(s)
        c.walletTokenBalance = 5_000; c.walletRegistered = true; c.guardRegistered = true
        let r = try review(.depositToken(token: gtt, amount: 500), c)
        XCTAssertEqual(r.title, "Add 0.0005 GTT to Budgets"); XCTAssertEqual(r.balanceBefore, 900)
        XCTAssertTrue(r.lines.contains(["Network fee", "Up to 0.04 NEAR"]))
        XCTAssertTrue(r.checks.contains { $0.contains("registered with GTT") })
        c.guardRegistered = false
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), c).contains("Budgets contract isn't registered with GTT"))
        c.guardRegistered = true; c.walletRegistered = false
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), c).contains("This wallet isn't registered with GTT"))
        c.walletRegistered = true; c.walletTokenBalance = 100
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), c).contains("You have 0.0001 GTT"))
        c.walletTokenBalance = nil
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), c).contains("Couldn't read"))
        c.walletTokenBalance = 5_000; c.guardRegistered = nil
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), c).contains("isn't registered"))
        XCTAssertTrue(blocked(.depositToken(token: "near", amount: 500), context(s)).contains("Not a valid amount"))
        XCTAssertTrue(blocked(.depositToken(token: usdc, amount: 500), context(s)).contains("can't read that token"))
        // No vault yet: tokens sent to the contract would be handed back, so the app doesn't send them.
        XCTAssertTrue(blocked(.depositToken(token: gtt, amount: 500), context(try snapshot(vault: .some(nil)))).contains("Set up Budgets first"))
    }

    func testDepositNearAndOpenVault() throws {
        let s = try snapshot()
        let r = try review(.depositNear(2 * near), context(s))
        XCTAssertEqual(r.title, "Add 2 NEAR to Budgets"); XCTAssertEqual(r.usd, nil)       // no price in this test
        XCTAssertTrue(r.lines.contains(["In the vault now", "0.3 NEAR"]))
        XCTAssertTrue(blocked(.depositNear(10 * near), context(s)).contains("Not enough NEAR"))
        XCTAssertTrue(blocked(.depositNear(0), context(s)).contains("Not a valid amount"))
        // Opening: the storage deposit is read from the contract; the first deposit goes on top.
        let none = try snapshot(vault: .some(nil))
        let o = try review(.openVault(storage: NearGuard.storageDeposit, initial: near), context(none))
        XCTAssertTrue(o.lines.contains(["Leaves your account", "1.5 NEAR"])); XCTAssertTrue(o.lines.contains { $0[0] == "Storage deposit" && $0[1].contains("refunded") })
        XCTAssertTrue(o.warnings.contains { $0.contains("hasn't been audited") })
        XCTAssertTrue(blocked(.openVault(storage: NearGuard.storageDeposit, initial: 0), context(s)).contains("already have a Budgets vault"))
        XCTAssertTrue(blocked(.openVault(storage: near / 10, initial: 0), context(none)).contains("isn't what Hermit expects"))
        XCTAssertTrue(blocked(.openVault(storage: NearGuard.storageDeposit, initial: 0), context(none, available: near / 2)).contains("Not enough NEAR"))
        XCTAssertTrue(blocked(.openVault(storage: NearGuard.storageDeposit, initial: UInt128.max), context(none)).contains("Not enough NEAR"))   // no overflow
        var big = none; big.storageCost = 2 * near
        XCTAssertTrue(blocked(.openVault(storage: 2 * near, initial: 0), context(big)).contains("isn't what Hermit expects"))
    }

    func testMovesThatGrantAuthorityNeedTheCheckedCode() throws {
        let s = try snapshot()
        var c = context(s)
        c.codeHash = "11111111111111111111111111111111111111111111"
        XCTAssertTrue(blocked(.depositNear(near), c).contains("isn't the version Hermit checked"))
        XCTAssertTrue(blocked(.createPocket(.init(name: "x", token: "near", perPayment: 1, daily: 1)), c).contains("isn't the version Hermit checked"))
        // Getting money out and stopping things must keep working, whatever the code is.
        XCTAssertNoThrow(try review(.withdraw(token: "near", amount: nil), c))
        XCTAssertNoThrow(try review(.setFrozen(true), c))
        XCTAssertNoThrow(try review(.removePocket(name: "rent"), c))
        c.codeHash = nil
        XCTAssertTrue(blocked(.depositNear(near), c).contains("Couldn't read the Budgets contract's code"))
        // Keys on the contract's account are said out loud.
        c.codeHash = GuardConfig.testnetCodeHash; c.accessKeys = 2
        XCTAssertTrue(try review(.depositNear(near), c).warnings.contains { $0.contains("2 access keys") })
        c.accessKeys = 0
        XCTAssertTrue(try review(.depositNear(near), c).checks.contains("No one can change the contract's code"))
    }

    func testWithdrawFreezeAndClose() throws {
        let s = try snapshot()
        let all = try review(.withdraw(token: "near", amount: nil), context(s))
        XCTAssertEqual(all.title, "Withdraw all 0.3 NEAR from Budgets"); XCTAssertTrue(all.lines.contains(["To", "Your NEAR account"]))
        XCTAssertTrue(all.checks.contains("Always works, also while the vault is frozen"))
        let part = try review(.withdraw(token: "near", amount: near / 10), context(s))
        XCTAssertTrue(part.lines.contains(["Left in the vault", "0.2 NEAR"])); XCTAssertEqual(part.title, "Withdraw 0.1 NEAR from Budgets")
        XCTAssertTrue(blocked(.withdraw(token: "near", amount: near), context(s)).contains("The vault holds 0.3 NEAR"))
        // The wallet has to be able to receive the token, or the contract would only put it back.
        var c = context(s); c.walletRegistered = false
        XCTAssertTrue(blocked(.withdraw(token: gtt, amount: nil), c).contains("isn't registered with GTT"))
        c.walletRegistered = true
        XCTAssertNoThrow(try review(.withdraw(token: gtt, amount: 100), c))
        // A frozen vault can still be withdrawn from, and unfrozen; freezing twice is refused.
        let frozen = try snapshot(vault: .some(vault([.init(token: "near", amount: near)], frozen: true)))
        XCTAssertNoThrow(try review(.withdraw(token: "near", amount: nil), context(frozen)))
        XCTAssertNoThrow(try review(.setFrozen(false), context(frozen)))
        XCTAssertTrue(blocked(.setFrozen(true), context(frozen)).contains("already frozen"))
        XCTAssertTrue(blocked(.setFrozen(false), context(s)).contains("isn't frozen"))
        // Empty vault: nothing to withdraw.
        XCTAssertTrue(blocked(.withdraw(token: "near", amount: nil), context(try snapshot(vault: .some(vault([]))))).contains("no NEAR in the vault"))
        // Closing needs an empty vault, no pockets and nothing in flight.
        XCTAssertTrue(blocked(.closeVault, context(s)).contains("Withdraw everything"))
        let empty = vault([.init(token: "near", amount: 0)])
        XCTAssertTrue(blocked(.closeVault, context(try snapshot(vault: .some(empty)))).contains("Remove your pockets first"))
        XCTAssertTrue(blocked(.closeVault, context(try snapshot(vault: .some(vault([], pendingOut: 1)), pockets: [], orders: []))).contains("still on its way"))
        let close = try review(.closeVault, context(try snapshot(vault: .some(empty), pockets: [], orders: [])))
        XCTAssertTrue(close.lines.contains(["You get back", "0.5 NEAR, the storage deposit"]))
    }

    func testApproveShowsWhatIsBeingOverridden() throws {
        let req = NearGuard.GuardRequest(id: 3, pocket: "coffee", token: "near", amount: 3 * near / 2, recipient: "newshop.near", reason: "new laptop", createdNs: now - 3_600_000_000_000)
        let rich = vault([.init(token: "near", amount: 5 * near)])
        var c = context(try snapshot(vault: .some(rich), requests: [req]))
        c.recipientReady = true
        let r = try review(.approve(3), c)
        XCTAssertEqual(r.title, "Approve 1.5 NEAR to newshop.near")
        XCTAssertTrue(r.lines.contains(["Their reason", "\u{201C}new laptop\u{201D}"])); XCTAssertTrue(r.lines.contains(["To", "newshop.near"]))
        XCTAssertTrue(r.warnings.contains("This is more than the pocket's limit of 0.5 NEAR per payment. Approving overrides the limit."))
        XCTAssertTrue(r.warnings.contains { $0.contains("isn't on the pocket's list of recipients") })
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("First payment to newshop.near") })
        XCTAssertTrue(r.warnings.contains("The reason is written by whoever holds the key, not by Hermit."))
        // Not payable: the recipient can't receive it, or that couldn't be checked.
        c.recipientReady = false
        XCTAssertTrue(blocked(.approve(3), c).contains("doesn't exist on NEAR"))
        c.recipientReady = nil
        XCTAssertTrue(blocked(.approve(3), c).contains("Couldn't check whether newshop.near can receive"))
        c.recipientReady = true
        XCTAssertTrue(blocked(.approve(9), c).contains("request is gone"))
        // The vault is short, frozen, or the request has expired.
        XCTAssertTrue(blocked(.approve(3), context(try snapshot(vault: .some(vault([.init(token: "near", amount: near)])), requests: [req]))).contains("not enough"))
        var f = context(try snapshot(vault: .some(vault([.init(token: "near", amount: 5 * near)], frozen: true)), requests: [req])); f.recipientReady = true
        XCTAssertTrue(blocked(.approve(3), f).contains("frozen"))
        var late = c; late.nowNs = req.expiresNs
        XCTAssertTrue(blocked(.approve(3), late).contains("expired"))
        // Reject only needs the request to exist.
        XCTAssertEqual(try review(.reject(3), c).title, "Reject the request for 1.5 NEAR")
    }

    func testOrdersAndPocketStates() throws {
        let s = try snapshot()
        let order = NearGuard.OrderDraft(pocket: "coffee", amount: near / 5, recipient: shop, intervalSeconds: 1_209_600, remaining: 4, memo: "beans")
        let r = try review(.createOrder(order), context(s))
        XCTAssertTrue(r.lines.contains(["How often", "Every 2 weeks"])); XCTAssertTrue(r.lines.contains(["Runs", "4 times, 0.8 NEAR in all"]))
        XCTAssertTrue(r.lines.contains(["Pays", "0.2 NEAR to \(shop)"])); XCTAssertTrue(r.lines.contains(["Note", "beans"]))
        XCTAssertTrue(r.warnings.contains { $0.contains("even when your phone is off") })
        var forever = order; forever.remaining = nil
        XCTAssertTrue(try review(.createOrder(forever), context(s)).lines.contains(["Runs", "Until you cancel it"]))
        var over = order; over.amount = near
        XCTAssertTrue(blocked(.createOrder(over), context(s)).contains("within the pocket's limit"))
        var stranger = order; stranger.recipient = "stranger.near"
        XCTAssertTrue(blocked(.createOrder(stranger), context(s)).contains("doesn't allow payments to stranger.near"))
        var ghost = order; ghost.pocket = "ghost"
        XCTAssertTrue(blocked(.createOrder(ghost), context(s)).contains("no pocket called ghost"))
        let many = (0..<20).map { NearGuard.GuardOrder(id: UInt64($0), pocket: "coffee", token: "near", amount: 1, recipient: shop, intervalSeconds: 3600, nextDueNs: 1, remaining: nil, memo: "") }
        XCTAssertTrue(blocked(.createOrder(order), context(try snapshot(orders: many))).contains("20 standing orders"))
        XCTAssertEqual(try review(.cancelOrder(2), context(s)).title, "Cancel the order to \(shop)")
        XCTAssertTrue(blocked(.cancelOrder(99), context(s)).contains("doesn't exist any more"))
        // Pause and resume.
        XCTAssertEqual(try review(.setPaused(name: "coffee", paused: true), context(s)).title, "Pause pocket coffee")
        XCTAssertTrue(blocked(.setPaused(name: "coffee", paused: false), context(s)).contains("isn't paused"))
        // Resuming a paused pocket says what it can pay again.
        let sleeping = NearGuard.GuardPocket(name: "coffee", publicKey: nil, token: "near", perPaymentCap: near / 2, dailyCap: near, spent: 0, windowStart: 0,
                                             allowedRecipients: [], expiresAt: nil, paused: true)
        let back = try review(.setPaused(name: "coffee", paused: false), context(try snapshot(pockets: [sleeping])))
        XCTAssertEqual(back.title, "Resume pocket coffee")
        XCTAssertTrue(back.warnings.contains("The pocket coffee can pay up to 0.5 NEAR per payment and 1 NEAR per day without asking you."))
    }

    func testSpendingPolicyCountsMoneyIntoTheVault() throws {
        let s = try snapshot()
        var c = context(s)
        c.usdPerUnit = 2
        let r = try review(.depositNear(5 * near), c)
        XCTAssertEqual(r.usd, 10)
        // Over the daily limit: blocked, with the policy's words.
        let d = UserDefaults(suiteName: "guard-limit-\(UUID())")!
        let limit = SpendLimit(defaults: d); limit.record(usd: limit.dailyLimitUSD - 5)
        let tight = SpendPolicy(limit: limit, book: AddressBook(defaults: d), defaults: d)
        do { _ = try NearGuard.review(.depositNear(5 * near), walletID: wallet, account: implicit, context: c, policy: tight, origin: .user); XCTFail("expected a block") }
        catch WalletError.blocked(let why) { XCTAssertTrue(why.contains("daily limit")) }
        // Getting money out isn't spending.
        XCTAssertNil(try review(.withdraw(token: "near", amount: nil), c).usd)
    }
}
