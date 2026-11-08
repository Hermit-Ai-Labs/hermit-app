#!/bin/bash
# The NEAR-relevant unit tests on macOS without building MLX or the UI (a few minutes on any Mac with Xcode 26):
# HermitCoreTests (tool loop, prompt injection, ToolGuard), HermitWalletTests (NEAR keys and transactions, 1Click
# quotes and signatures, spending policy) and HermitCloudTests (TDX attestation, TLS binding, response signatures).
#
#   bash scripts/core-tests.sh                                   # all three test targets
#   bash scripts/core-tests.sh --filter 'ToolLoopTests|testSpendPolicy'
#   ONECLICK_LIVE=1 bash scripts/core-tests.sh --filter NearIntentsTests/testLiveDryQuote
#
# It copies HermitCore, HermitWallet and HermitCloud with their tests into a scratch package (same sources, same
# pinned dependencies as Packages/HermitKit/Package.swift, minus MLX and SwiftUI). The full suite, snapshots
# included, is `cd Packages/HermitKit && swift test`.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
K=$ROOT/Packages/HermitKit
P=${HERMIT_CORE_PKG:-${TMPDIR:-/tmp}/hermit-core-tests}
rm -rf "$P/Sources" "$P/Tests"; mkdir -p "$P/Sources" "$P/Tests"
cp -R "$K/Sources/HermitCore" "$K/Sources/HermitWallet" "$K/Sources/HermitCloud" "$P/Sources/"
cp -R "$K/Tests/HermitCoreTests" "$K/Tests/HermitWalletTests" "$K/Tests/HermitCloudTests" "$P/Tests/"
cat > "$P/Package.swift" <<'PKG'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HermitCoreTests", platforms: [.macOS(.v26), .iOS(.v26)],
  dependencies: [
    .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.9.0"),
  ],
  targets: [
    .target(name: "HermitCore"),
    .target(name: "HermitWallet", dependencies: ["HermitCore", .product(name: "libsecp256k1", package: "swift-secp256k1"),
             .product(name: "CryptoSwift", package: "CryptoSwift")], resources: [.copy("Resources/bip39-english.txt")]),
    .target(name: "HermitCloud", dependencies: ["HermitCore", .product(name: "libsecp256k1", package: "swift-secp256k1"),
             .product(name: "CryptoSwift", package: "CryptoSwift")], resources: [.process("Resources")]),
    .testTarget(name: "HermitCoreTests", dependencies: ["HermitCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "HermitWalletTests", dependencies: ["HermitWallet"], resources: [.copy("Fixtures")]),
    .testTarget(name: "HermitCloudTests", dependencies: ["HermitCloud"], resources: [.copy("Fixtures")]),
  ], swiftLanguageModes: [.v5])
PKG
cd "$P" && swift test "$@"
