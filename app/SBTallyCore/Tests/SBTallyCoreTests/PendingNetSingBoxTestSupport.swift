import Foundation
@testable import SBTallyCore

/// Tests prefer the exact binary a caller asks them to accept. The embed build phase sets
/// `PENDINGNET_SING_BOX` to the just-compiled bundle candidate, so these checks no longer
/// accidentally prove only that an unrelated Homebrew copy understands the config.
func pendingNetSingBoxForTests() -> String? {
    let requested = ProcessInfo.processInfo.environment["PENDINGNET_SING_BOX"]
    return ([requested].compactMap { $0 } + PendingNetEngineBinary.fallbackPaths)
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
