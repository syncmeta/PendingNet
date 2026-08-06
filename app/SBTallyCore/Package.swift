// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SBTallyCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SBTallyCore", targets: ["SBTallyCore"]),
    ],
    targets: [
        .target(name: "SBTallyCore"),
        .testTarget(name: "SBTallyCoreTests", dependencies: ["SBTallyCore"]),
    ]
)
