import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class EngineController: ObservableObject {
    @Published var running = false
    @Published var takeover = "tun"
    @Published var helperReady = false
    @Published var lastError: String?
    @Published var logTail: String = ""
    /// Set after a `start()` attempt whose post-refresh status shows the
    /// engine still isn't running — signals the GUI should surface `logTail`.
    @Published var startFailed = false

    private let service = SMAppService.daemon(plistName: "net.pending.PendingNet.helper.plist")

    /// A single, cached XPC connection — reused across calls instead of
    /// creating (and leaking) a new one per toggle/refresh.
    private var connection: NSXPCConnection?

    /// Resumes a `CheckedContinuation` exactly once, whichever of the two
    /// competing paths (the XPC reply closure, or the proxy's error handler
    /// firing because the connection is down/interrupted) gets there first.
    /// Without this, an error-handler-only failure would leave the
    /// continuation — and the calling `await` — hung forever.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<T, Never>
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            lock.lock()
            let alreadyResumed = didResume
            didResume = true
            lock.unlock()
            guard !alreadyResumed else { return }
            continuation.resume(returning: value)
        }
    }

    /// Returns the cached connection, creating it on first use. Registers
    /// interruption/invalidation handlers so a dead connection is dropped
    /// (and rebuilt on next call) instead of being reused in a broken state.
    private func xpcConnection() -> NSXPCConnection {
        if let existing = connection { return existing }
        let c = NSXPCConnection(machServiceName: "net.pending.PendingNet.helper",
                                 options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil; self?.helperReady = false }
        }
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil; self?.helperReady = false }
        }
        c.resume()
        connection = c
        return c
    }

    /// Calls `body` with the helper proxy, delivering exactly one result:
    /// either what `body` reports via its `reply` callback, or `fallback` if
    /// the proxy can't be obtained or the connection's error handler fires
    /// first (helper not registered, connection interrupted, etc).
    private func withHelper<T: Sendable>(
        _ fallback: T,
        _ body: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T {
        let conn = xpcConnection()
        return await withCheckedContinuation { (k: CheckedContinuation<T, Never>) in
            let once = ResumeOnce(k)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription; self?.helperReady = false }
                once.resume(fallback)
            } as? HelperProtocol
            guard let proxy else {
                once.resume(fallback)
                return
            }
            body(proxy, { value in once.resume(value) })
        }
    }

    func registerHelper() {
        do { try service.register(); helperReady = true }
        catch { lastError = "助手授权失败：\(error.localizedDescription)" }
    }

    func refresh() async {
        helperReady = service.status == .enabled
        guard helperReady else { return }
        let result: (Bool, String, String)? = await withHelper(nil) { p, reply in
            p.status { run, mode, tail in reply((run, mode, tail)) }
        }
        guard let result else { return }
        running = result.0
        takeover = result.1
        logTail = result.2
    }

    private func call(_ f: @escaping (HelperProtocol, @escaping (String?) -> Void) -> Void) async {
        let err: String? = await withHelper("助手连接失败") { p, reply in
            f(p) { reply($0) }
        }
        if let err { lastError = err }
        await refresh()
    }

    func start() async {
        await call { p, r in p.startEngine(reply: r) }
        startFailed = !running
    }
    func stop() async {
        startFailed = false
        await call { p, r in p.stopEngine(reply: r) }
    }
    func setTakeover(_ m: String) async { await call { p, r in p.setTakeover(m, reply: r) } }

    deinit {
        connection?.invalidate()
    }
}
