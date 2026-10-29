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
    ],
    targets: [
        .target(name: "HermitCore"),
        .target(name: "HermitUI", dependencies: ["HermitCore"], resources: [.process("Resources")]),
        .testTarget(name: "HermitUITests", dependencies: ["HermitUI"]),
    ],
    swiftLanguageModes: [.v5]
)
