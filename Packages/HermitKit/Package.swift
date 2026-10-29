// swift-tools-version: 6.2
// HermitKit: everything the Mac and iPhone apps share. The app targets are thin shells around it.
//   HermitCore  models, the agent, wallet and chain code. No UI.
//   HermitModel the on-device model (MLX): download, load, stream. Keeps MLX out of HermitCore.
//   HermitUI    the design system and every screen, in SwiftUI.
import PackageDescription

let package = Package(
    name: "HermitKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HermitCore", targets: ["HermitCore"]),
        .library(name: "HermitModel", targets: ["HermitModel"]),
        .library(name: "HermitUI", targets: ["HermitUI"]),
    ],
    dependencies: [
        // Apple's MLX LLM library, plus Hugging Face tokenizers so the model's own chat template is used.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "HermitCore"),
        .target(name: "HermitModel", dependencies: [
            "HermitCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "HermitUI", dependencies: ["HermitCore", "HermitModel"], resources: [.process("Resources")]),
        .testTarget(name: "HermitUITests", dependencies: ["HermitUI"]),
    ],
    swiftLanguageModes: [.v5]
)
