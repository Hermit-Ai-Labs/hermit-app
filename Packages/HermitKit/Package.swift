// swift-tools-version: 6.2
// HermitKit: everything the Mac and iPhone apps share. The app targets are thin shells around it.
//   HermitCore  models, the agent, wallet and chain code. No UI.
//   HermitUI    the design system and every screen, in SwiftUI.
import PackageDescription

let package = Package(
    name: "HermitKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HermitCore", targets: ["HermitCore"]),
        .library(name: "HermitUI", targets: ["HermitUI"]),
        .library(name: "HermitWallet", targets: ["HermitWallet"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.9.0"),
    ],
    targets: [
        .target(name: "HermitCore"),
        // HermitWallet: keys, Keychain + Secure Enclave, EVM and Solana clients, signing.
        .target(name: "HermitWallet", dependencies: [
            "HermitCore",
            .product(name: "libsecp256k1", package: "swift-secp256k1"),
            .product(name: "CryptoSwift", package: "CryptoSwift"),
        ], resources: [.copy("Resources/bip39-english.txt")]),
        .target(name: "HermitUI", dependencies: ["HermitCore", "HermitWallet"], resources: [.process("Resources")]),
        .testTarget(name: "HermitUITests", dependencies: ["HermitUI"]),
        .testTarget(name: "HermitWalletTests", dependencies: ["HermitWallet"]),
    ],
    swiftLanguageModes: [.v5]
)
