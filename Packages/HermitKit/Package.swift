// swift-tools-version: 6.2
// HermitKit: everything the Mac and iPhone apps share. The app targets are thin shells around it.
//   HermitCore  models, the agent, wallet and chain code. No UI.
//   HermitModel the on-device model (MLX): download, load, stream. Keeps MLX out of HermitCore.
//   HermitWallet keys (Secure Enclave), EVM and Solana clients, signing.
//   HermitUI    the design system and every screen, in SwiftUI.
//   HermitActivity the model-download Live Activity's data, shared with the iPhone widget extension. No dependencies.
import PackageDescription

let package = Package(
    name: "HermitKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HermitCore", targets: ["HermitCore"]),
        .library(name: "HermitModel", targets: ["HermitModel"]),
        .library(name: "HermitUI", targets: ["HermitUI"]),
        .library(name: "HermitWallet", targets: ["HermitWallet"]),
        .library(name: "HermitActivity", targets: ["HermitActivity"]),
        .library(name: "HermitCloud", targets: ["HermitCloud"]),
    ],
    dependencies: [
        // Wallet: bitcoin-core libsecp256k1 and Keccak-256.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.9.0"),
        // Apple's MLX LLM library, plus Hugging Face tokenizers so the model's own chat template is used.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "HermitCore"),
        .target(name: "HermitActivity"),
        .target(name: "HermitModel", dependencies: [
            "HermitCore",
            "HermitActivity",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // HermitWallet: keys, Keychain + Secure Enclave, EVM and Solana clients, signing.
        .target(name: "HermitWallet", dependencies: [
            "HermitCore",
            .product(name: "libsecp256k1", package: "swift-secp256k1"),
            .product(name: "CryptoSwift", package: "CryptoSwift"),
        ], resources: [.copy("Resources/bip39-english.txt")]),
        // HermitCloud: Private Cloud mode on NEAR AI Cloud (TEE inference), and the on-device attestation checks behind it.
        .target(name: "HermitCloud", dependencies: [
            "HermitCore",
            .product(name: "libsecp256k1", package: "swift-secp256k1"),
            .product(name: "CryptoSwift", package: "CryptoSwift"),
        ], resources: [.copy("Resources/hermit_tools.json")]),
        .target(name: "HermitUI", dependencies: ["HermitCore", "HermitModel", "HermitWallet", "HermitCloud"], resources: [.process("Resources")]),
        .testTarget(name: "HermitCoreTests", dependencies: ["HermitCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HermitUITests", dependencies: ["HermitUI"]),
        .testTarget(name: "HermitWalletTests", dependencies: ["HermitWallet"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HermitCloudTests", dependencies: ["HermitCloud"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
