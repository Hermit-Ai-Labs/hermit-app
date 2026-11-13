import XCTest
@testable import HermitWallet

final class BlackBoxTests: XCTestCase {
    /// The app and near/blackbox.py must compute the same pin digest, or the registry check fails for everyone.
    func testPinDigestMatchesThePythonScript() {
        let files: [(path: String, size: Int64, sha256: String)] = [
            ("generation_config.json", 174, "b85588c5a41e2eb6667442f752ea5d2ecbe310ef6189f0fde59a6479ff1921eb"),
            ("tokenizer_config.json", 730, "400c3ab7c84026ef441e0223425c8724f11057171df2c149a544825d3296afb7"),
            ("config.json", 2014, "57b401ce4fbcaf1f274d6eae966cf54e797606251b9257dc08c3fc673449b382"),
            ("chat_template.jinja", 20608, "54d9902baeabad15c999840a8a42bf8ef0ce51dfee230b3fe12d79a9676c1118"),
            ("model.safetensors.index.json", 63964, "fd9ab512823b83d11ba1886e2742f9683a26ed1fe570e6f36705ad311033512d"),
            ("tokenizer.json", 11422650, "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
            ("model.safetensors", 2765806707, "3cd5cb7b3511d03872a80ec01d8ae95d7f6444af66549c78621d39d8b23c9fca"),
        ]
        // `python3 near/blackbox.py digests`, Hermit 1.3
        XCTAssertEqual(BlackBox.pinDigest(files: files), "387ec7d04a39a40db1f0c1a320e6f424245412495d25f145a6032807d230e7c9")
        XCTAssertEqual(BlackBox.pinDigest(files: files.reversed()), BlackBox.pinDigest(files: files), "order of the pin must not matter")
    }

    func testFingerprintIsSaltedAndCoversTheReview() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        func fp(_ title: String, salt: String) -> (fp: String, preimage: String) {
            BlackBox.fingerprint(kind: "Swap", title: title, lines: [["Pay", "20 USDC"], ["Get", "9.1 NEAR"]], checks: ["Signed quote"],
                                 warnings: [], result: "Swapped", tx: "abc", model: "aiquantgod/Hermit-1.3-4B-MLX-5bit", at: d, salt: salt)
        }
        let a = fp("Swap 20 USDC", salt: "00")
        XCTAssertEqual(a.fp, fp("Swap 20 USDC", salt: "00").fp, "same input, same fingerprint")
        XCTAssertNotEqual(a.fp, fp("Swap 20 USDC", salt: "01").fp, "the salt makes it unguessable")
        XCTAssertNotEqual(a.fp, fp("Swap 21 USDC", salt: "00").fp)
        XCTAssertEqual(a.fp.count, 64)
        XCTAssertTrue(a.preimage.contains("20 USDC") && a.preimage.contains("\"salt\":\"00\""))
        XCTAssertEqual(BlackBox.randomHex(16).count, 32)
    }

    func testKindSlugIsWhatTheContractAccepts() {
        XCTAssertEqual(BlackBox.kindSlug("Perp order"), "perp_order")
        XCTAssertEqual(BlackBox.kindSlug("Swap"), "swap")
        XCTAssertEqual(BlackBox.kindSlug("💸"), "move")
        XCTAssertLessThanOrEqual(BlackBox.kindSlug(String(repeating: "a", count: 80)).count, 32)
        XCTAssertTrue(BlackBox.kindSlug("Send → Bob!").allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    }
}
