import Foundation
import SBTallyCore
import ServiceManagement
import SwiftUI

@MainActor
final class EngineController: ObservableObject {
    @Published var running = false
    @Published var takeover = "local"
    @Published var helperReady = false
    @Published var lastError: String?
    @Published var logTail: String = ""
    /// Set after a `start()` attempt whose post-refresh status shows the
    /// engine still isn't running — signals the GUI should surface `logTail`.
    @Published var startFailed = false

    private let service = SMAppService.daemon(plistName: "net.pending.PendingNet.helper.plist")
    private let userEngine = PendingNetUserEngine()

    var localProxyPort: Int { userEngine.proxyPort }

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
        @discardableResult
        func resume(_ value: T) -> Bool {
            lock.lock()
            let alreadyResumed = didResume
            didResume = true
            lock.unlock()
            guard !alreadyResumed else { return false }
            continuation.resume(returning: value)
            return true
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
                if once.resume(fallback) {
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.helperReady = false
                    }
                }
            } as? HelperProtocol
            guard let proxy else {
                once.resume(fallback)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if once.resume(fallback) {
                    await MainActor.run {
                        self?.lastError = "特权助手没有响应，请重新授权"
                        self?.helperReady = false
                    }
                }
            }
            body(proxy, { value in once.resume(value) })
        }
    }

    func registerHelper() {
        Task {
            do {
                // Ad-hoc development builds created before 0.3.5 had a
                // version-specific code identity. Remove that stale Service
                // Management registration before registering the current app.
                switch service.status {
                case .enabled, .requiresApproval:
                    try await service.unregister()
                case .notRegistered, .notFound:
                    break
                @unknown default:
                    break
                }
                try service.register()
                helperReady = service.status == .enabled
                lastError = helperReady
                    ? nil
                    : "请在系统设置 → 通用 → 登录项与扩展中允许 PendingNet 后台项目"
            } catch {
                helperReady = false
                lastError = "助手授权失败：\(error.localizedDescription)"
            }
        }
    }

    func refresh() async {
        helperReady = service.status == .enabled
        if takeover == "local" {
            running = userEngine.isRunning
            logTail = userEngine.logTail()
            return
        }
        guard helperReady else {
            running = false
            return
        }
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
        if takeover == "local" {
            do {
                try await userEngine.start()
                running = true
                lastError = nil
                startFailed = false
            } catch {
                running = false
                lastError = error.localizedDescription
                logTail = userEngine.logTail()
                startFailed = true
            }
            return
        }
        await call { p, r in p.startEngine(reply: r) }
        startFailed = !running
    }
    func stop() async {
        startFailed = false
        if takeover == "local" {
            await userEngine.stop()
            running = false
            lastError = nil
            return
        }
        await call { p, r in p.stopEngine(reply: r) }
    }
    func setTakeover(_ mode: String) async {
        guard ["local", "sysproxy", "tun"].contains(mode), mode != takeover else { return }
        if mode == "local" {
            if running { await call { p, r in p.stopEngine(reply: r) } }
            takeover = "local"
            running = userEngine.isRunning
            lastError = nil
            return
        }
        guard helperReady else {
            lastError = "系统代理和 TUN 需要已公证版本的后台服务；当前可直接使用“仅端口”。"
            return
        }
        if takeover == "local", running { await userEngine.stop() }
        takeover = mode
        await call { p, r in p.setTakeover(mode, reply: r) }
    }

    func applyServerConfiguration(_ runtime: PendingNetRuntimeServer) async -> Bool {
        if takeover == "local" {
            do {
                try await userEngine.apply(runtime)
                running = userEngine.isRunning
                lastError = nil
                logTail = userEngine.logTail()
                return true
            } catch {
                lastError = error.localizedDescription
                logTail = userEngine.logTail()
                return false
            }
        }
        let err: String? = await withHelper("特权助手尚未就绪") { p, reply in
            p.applyServerConfiguration(
                runtime.serverID,
                name: runtime.name,
                selectorTag: runtime.selectorTag,
                proxyOutbounds: runtime.proxyOutbounds,
                reply: reply
            )
        }
        if let err {
            lastError = err
            return false
        }
        lastError = nil
        await refresh()
        return true
    }

    func stopBeforeTermination() {
        if takeover == "local" { userEngine.stopImmediately() }
    }

    deinit {
        connection?.invalidate()
    }
}
