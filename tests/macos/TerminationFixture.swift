import AppKit
import Foundation

// No real engine or helper is used by this fixture.
@MainActor final class EngineController {
    private var pending: CheckedContinuation<String?, Never>?
    func prepareForTermination() async -> String? {
        if CommandLine.arguments.contains("--no-reply") {
            return await withCheckedContinuation { pending = $0 }
        }
        return "simulated helper is unavailable"
    }
    func stopBeforeTermination() {}
}
@MainActor final class NSAlert {
    var messageText = ""
    var informativeText = ""
    func addButton(withTitle: String) {}
    func runModal() -> NSApplication.ModalResponse { .alertFirstButtonReturn }
}
@MainActor final class FixtureApplication: NSApplication {
    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        print(shouldTerminate ? "PASS: application exit permitted" : "FAIL: helper failure vetoed application exit")
        fflush(stdout)
        exit(shouldTerminate ? 0 : 42)
    }
}
@main enum Main {
    @MainActor static func main() async {
        let app = FixtureApplication()
        app.setActivationPolicy(.prohibited)
        let engine = EngineController()
        let delegate = PendingNetAppDelegate()
        delegate.engine = engine
        let answer = delegate.applicationShouldTerminate(app)
        guard answer == .terminateLater else { fatalError("Expected deferred cleanup") }
        try? await Task.sleep(for: .seconds(18))
        withExtendedLifetime((engine, delegate)) {}
        fatalError("Fixture did not exit within its deadline")
    }
}
