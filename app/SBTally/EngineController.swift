import Foundation
import SBTallyCore
import ServiceManagement
import SwiftUI

@MainActor
final class EngineController: ObservableObject {
    @Published var running = false
    @Published var takeover = "local"
    @Published var helperReady = false
    /// True while Service Management has the daemon registered but the user
    /// hasn't approved it yet in 系统设置 → 登录项与扩展. XPC calls fail with
    /// "Operation not permitted" in this state — that's pending approval,
    /// not a leftover legacy helper.
    @Published var helperNeedsApproval = false
    @Published var lastError: String?
    @Published var logTail: String = ""
    /// Set after a `start()` attempt whose post-refresh status shows the
    /// engine still isn't running — signals the GUI should surface `logTail`.
    @Published var startFailed = false

    private let service = SMAppService.daemon(plistName: "net.pending.PendingNet.helper.plist")
    /// 用户在助手就绪前选中的接管方式。授权成功后自动接着切过去，省得再点一次。
    private var pendingTakeover: String?
    /// The helper's mode is adopted once, at first refresh with a ready helper;
    /// afterwards the user's own choice wins.
    private var didAdoptHelperMode = false
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
    /// Timeout for cheap, near-instant helper calls (status polling).
    private static let quickTimeout: Duration = .seconds(5)
    /// Timeout for calls that launch or reconfigure sing-box: `waitForEngine`
    /// alone budgets 3s, on top of launchctl and full config validation. The
    /// old blanket 3s ceiling made these calls *always* report "特权助手没有响应".
    private static let engineTimeout: Duration = .seconds(60)

    private func withHelper<T: Sendable>(
        _ fallback: T,
        timeout: Duration,
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
                try? await Task.sleep(for: timeout)
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
            // A fresh authorization attempt starts from a clean slate — the
            // previous attempt's error must not outlive it.
            lastError = nil
            do {
                // An already-approved helper must be left alone: unregistering
                // it here knocked it back to 「待批准」, so pressing 授权 made
                // things strictly worse.
                if service.status == .enabled {
                    helperReady = true
                    helperNeedsApproval = false
                    if let pending = pendingTakeover {
                        pendingTakeover = nil
                        await setTakeover(pending)
                    }
                    return
                }
                // Ad-hoc development builds created before 0.3.5 had a
                // version-specific code identity. Remove that stale Service
                // Management registration before registering the current app.
                if service.status == .requiresApproval {
                    try await service.unregister()
                }
                try service.register()
                helperReady = service.status == .enabled
                helperNeedsApproval = service.status == .requiresApproval
                if helperReady {
                    lastError = nil
                    if let pending = pendingTakeover {
                        pendingTakeover = nil
                        await setTakeover(pending)
                    }
                } else {
                    pendingTakeover = nil
                    lastError = "请在系统设置 → 通用 → 登录项与扩展中允许 PendingNet 后台项目，然后再选一次接管方式"
                }
            } catch {
                pendingTakeover = nil
                helperReady = false
                lastError = "助手授权失败：\(error.localizedDescription)"
            }
        }
    }

    func refresh() async {
        let wasReady = helperReady
        helperReady = service.status == .enabled
        helperNeedsApproval = service.status == .requiresApproval
        if helperReady, !wasReady {
            // The helper just became approved — whatever failed while it
            // wasn't no longer describes the current state.
            lastError = nil
        }
        if helperReady {
            // A helper-owned system proxy with no engine behind it leaves the
            // whole machine unable to reach anything — clean it up on sight.
            _ = await withHelper(false, timeout: Self.quickTimeout) { p, reply in
                p.repairSystemProxy(reply: reply)
            }
        }
        if takeover == "local", !didAdoptHelperMode, helperReady {
            // `takeover` starts at "local", but the helper may well have the
            // machine in sysproxy/tun already. Trust the helper's mode over the
            // app's default, or the GUI claims 「仅端口」 while the system is not.
            didAdoptHelperMode = true
            if let mode = await helperStatus()?.1, mode != "local" {
                takeover = mode
            }
        }
        if takeover == "local" {
            running = userEngine.isRunning
            logTail = userEngine.logTail()
            return
        }
        guard helperReady else {
            running = false
            return
        }
        guard let result = await helperStatus() else { return }
        running = result.0
        takeover = result.1
        logTail = result.2
    }

    private func helperStatus() async -> (Bool, String, String)? {
        await withHelper(nil, timeout: Self.quickTimeout) { p, reply in
            p.status { run, mode, tail in reply((run, mode, tail)) }
        }
    }

    private func call(_ f: @escaping (HelperProtocol, @escaping (String?) -> Void) -> Void) async {
        let err: String? = await withHelper("助手连接失败", timeout: Self.engineTimeout) { p, reply in
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
        // 助手还没就绪时直接发起授权 —— 从前这里只报错，而「授权后台服务…」按钮
        // 又只在 takeover != "local" 时才出现，于是从默认的「仅端口」根本走不到
        // 授权入口，系统代理/TUN 永远切不过去。
        guard helperReady else {
            pendingTakeover = mode
            registerHelper()
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
        let err: String? = await withHelper("特权助手尚未就绪", timeout: Self.engineTimeout) { p, reply in
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
