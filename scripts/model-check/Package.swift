// swift-tools-version: 6.2
// Command-line check of the on-device model: downloads it with ModelStore, then times a few real replies.
// Build with xcodebuild (SwiftPM alone can't compile MLX's Metal shaders), see scripts/model-check.sh.
import PackageDescription

let package = Package(
    name: "model-check",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/HermitKit")],
    targets: [
        .executableTarget(name: "model-check", dependencies: [.product(name: "HermitModel", package: "HermitKit")]),
    ],
    swiftLanguageModes: [.v5]
)
