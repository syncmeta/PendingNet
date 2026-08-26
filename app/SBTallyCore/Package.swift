// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SBTallyCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SBTallyCore", targets: ["SBTallyCore"]),
        .executable(name: "PendingNetConfigFixture", targets: ["PendingNetConfigFixture"]),
    ],
    targets: [
        .target(name: "SBTallyCore"),
        .executableTarget(name: "PendingNetConfigFixture", dependencies: ["SBTallyCore"]),
        .testTarget(name: "SBTallyCoreTests", dependencies: ["SBTallyCore"]),
    ]
)
