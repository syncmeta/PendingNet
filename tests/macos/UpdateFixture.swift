import AppKit
import Foundation

@MainActor final class EngineController {
    private var pending: CheckedContinuation<String?, Never>?
    var cleanupCalls = 0
    func prepareForUpdate() async -> String? {
        cleanupCalls += 1
        if CommandLine.arguments.contains("--no-reply") {
            return await withCheckedContinuation { pending = $0 }
        }
        return "simulated stale helper"
    }
    func stopBeforeTermination() {}
}
@main enum UpdateFixture {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = EngineController()
        let lifecycle = PendingNetUpdateLifecycle()
        lifecycle.engine = engine
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: lifecycle, userDriverDelegate: nil)
        let item = SUAppcastItem(dictionary: [
            "title": "Fixture", "sparkle:version": "1",
            "enclosure": ["url": "https://example.invalid/fixture.zip", "sparkle:version": "1"]
        ])!
        let delegate: SPUUpdaterDelegate = lifecycle
        let postponed = delegate.updater?(controller.updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            guard engine.cleanupCalls == 1 else { fatalError("Cleanup did not run exactly once") }
            print("PASS: actual Sparkle delegate performed pre-update cleanup and released installation")
            fflush(stdout)
            exit(0)
        })
        guard postponed == true else { fatalError("Sparkle did not call the cleanup delegate") }
        try? await Task.sleep(for: .seconds(18))
        withExtendedLifetime((engine, lifecycle, controller)) {}
        fatalError("Update callback did not resume within its deadline")
    }
}
