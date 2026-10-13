import AppKit

@MainActor
final class PendingNetAppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: EngineController?
    private var waitingForCleanup = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !waitingForCleanup else { return .terminateLater }
        guard let engine else { return .terminateNow }
        waitingForCleanup = true
        Task {
            let error = await engine.prepareForTermination()
            if let error {
                waitingForCleanup = false
                let alert = NSAlert()
                alert.messageText = String(localized: "退出前恢复网络失败")
                alert.informativeText = error
                alert.addButton(withTitle: String(localized: "确定"))
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
