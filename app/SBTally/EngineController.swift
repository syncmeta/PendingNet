import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class EngineController: ObservableObject {
    @Published var running = false
    @Published var takeover = "tun"
    @Published var helperReady = false
    @Published var lastError: String?

    private let service = SMAppService.daemon(plistName: "net.pending.PendingNet.helper.plist")

    private func proxy() -> HelperProtocol? {
        let c = NSXPCConnection(machServiceName: "net.pending.PendingNet.helper",
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.resume()
        return c.remoteObjectProxyWithErrorHandler { [weak self] e in
            Task { @MainActor in self?.lastError = e.localizedDescription; self?.helperReady = false }
        } as? HelperProtocol
    }

    func registerHelper() {
        do { try service.register(); helperReady = true }
        catch { lastError = "助手授权失败：\(error.localizedDescription)" }
    }
    func refresh() async {
        helperReady = service.status == .enabled
        guard helperReady, let p = proxy() else { return }
        await withCheckedContinuation { k in
            p.status { run, mode, _ in
                Task { @MainActor in self.running = run; self.takeover = mode; k.resume() }
            }
        }
    }
    private func call(_ f: (HelperProtocol, @escaping (String?) -> Void) -> Void) async {
        guard let p = proxy() else { return }
        await withCheckedContinuation { k in
            f(p) { err in Task { @MainActor in self.lastError = err; k.resume() } }
        }
        await refresh()
    }
    func start() async { await call { p, r in p.startEngine(reply: r) } }
    func stop() async { await call { p, r in p.stopEngine(reply: r) } }
    func setTakeover(_ m: String) async { await call { p, r in p.setTakeover(m, reply: r) } }
}
