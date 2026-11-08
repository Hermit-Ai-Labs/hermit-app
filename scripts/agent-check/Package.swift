// swift-tools-version: 6.2
// Command-line check of the on-device tool loop with the real model: loads Hermit from a model folder and runs
// scripted prompts through LocalAgent with the app's toolbox. Build with xcodebuild (SwiftPM alone can't compile
// MLX's Metal shaders), see scripts/agent-check.sh.
import PackageDescription

let package = Package(
    name: "agent-check",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/HermitKit")],
    targets: [
        .executableTarget(name: "agent-check", dependencies: [
            .product(name: "HermitModel", package: "HermitKit"),
            .product(name: "HermitUI", package: "HermitKit"),
            .product(name: "HermitWallet", package: "HermitKit"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
