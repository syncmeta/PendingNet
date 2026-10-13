import AppKit
import SBTallyCore

@MainActor
final class PendingNetAppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: EngineController?
    private var waitingForCleanup = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !waitingForCleanup else { return .terminateLater }
        guard let engine else { return .terminateNow }
        waitingForCleanup = true
        let gate = PendingNetTerminationGate()
        let cleanup = Task { await engine.prepareForTermination() }
        Task {
            let error = await cleanup.value
            guard gate.finish() else { return }
            if let error { NSLog("PendingNet termination cleanup: %@", error) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            try? await Task.sleep(for: .seconds(12))
            guard gate.finish() else { return }
            cleanup.cancel()
            engine.stopBeforeTermination()
            NSLog("PendingNet termination cleanup timed out; allowing application exit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
