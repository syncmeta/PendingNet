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

    /// 本机代理端口与监听范围。设置页可改；连接页不再显示。
    @Published private(set) var localProxyPort: Int
    @Published private(set) var allowsLAN: Bool

    /// 界面上显示的监听地址 —— 允许局域网访问时就是 0.0.0.0。
    var localListenAddress: String { userEngine.listenAddress }

    init() {
        localProxyPort = userEngine.proxyPort
        allowsLAN = userEngine.allowsLAN
    }

    /// 改端口 / 局域网访问。返回 nil 表示成功，否则是给用户看的人话。
    /// 引擎在跑的话会就地重启到新配置，不用用户自己去关了再开。
    func setLocalInbound(port: Int, allowLAN: Bool) async -> String? {
        do {
            try await userEngine.setLocalInbound(port: port, allowLAN: allowLAN)
            localProxyPort = userEngine.proxyPort
            allowsLAN = userEngine.allowsLAN
            running = userEngine.isRunning
            logTail = userEngine.logTail()
            return nil
        } catch {
            localProxyPort = userEngine.proxyPort
            allowsLAN = userEngine.allowsLAN
            running = userEngine.isRunning
            return error.localizedDescription
        }
    }

    /// Whether the app-run engine's config declares 白名单/黑名单 at all. Only
    /// meaningful in 「仅端口」 — the helper runs its own config.
    var listModesAvailable: Bool { userEngine.configDeclaresListModes }

    /// Fetches the geosite/geoip lists and rewrites the config to route by them,
    /// restarting the engine if it was up. Returns whether the list modes exist
    /// afterwards.
    func enableListModes() async -> Bool {
        let ok = await userEngine.enableListModes()
        running = userEngine.isRunning
        logTail = userEngine.logTail()
        return ok
    }

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
        // Pin the far end to a helper signed like this app. Without it the app
        // would talk to whatever claims the Mach service name.
        c.setCodeSigningRequirement(
            pendingNetCodeRequirement(identifier: "net.pending.PendingNet.helper"))
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.dropConnection() }
        }
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.dropConnection() }
        }
        c.resume()
        connection = c
        return c
    }

    /// Forgets the current connection along with everything only true of it —
    /// including which helper build was on the other end.
    private func dropConnection() {
        connection = nil
        helperReady = false
        helperInterfaceOK = nil
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

    /// Whether the helper answering on the current connection was built from
    /// this app's `HelperProtocol`. Nil until probed; reset whenever the
    /// connection is dropped, since a new one may reach a different build.
    private var helperInterfaceOK: Bool?
    /// Guards against re-registering the daemon on every refresh when recovery
    /// doesn't take: one attempt per connect-and-fail cycle, not a loop.
    private var didAttemptHelperRecovery = false

    /// Same as `withHelper`, but only after confirming the helper on the other
    /// end speaks this app's protocol — retiring it first if it doesn't.
    ///
    /// Every call goes through here. Sending even a long-standing method to a
    /// leftover helper is not harmless: it is the *old* code that would run,
    /// still carrying whichever bugs this version fixed.
    private func withCompatibleHelper<T: Sendable>(
        _ fallback: T,
        timeout: Duration,
        _ body: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void
    ) async -> T {
        guard await ensureHelperCompatible() else { return fallback }
        return await withHelper(fallback, timeout: timeout, body)
    }

    /// Replaces a helper left over from a previous install.
    ///
    /// Replacing the app bundle does not replace the running daemon: it is
    /// resident, launchd has no reason to restart it, and `register()` on an
    /// already-enabled service is a no-op. So an updated app keeps talking to
    /// the old binary until something here retires it — and the moment it calls
    /// a method that binary doesn't know, XPC drops the connection and the GUI
    /// falls back to 「等待授权」 forever.
    private func ensureHelperCompatible() async -> Bool {
        if let known = helperInterfaceOK { return known }
        var version = await probeHelperInterfaceVersion()
        // Same protocol but older code — a release that only fixed helper
        // behaviour — is stale too, or those fixes never take effect.
        var stale = version != pendingNetHelperInterfaceVersion
        if !stale { stale = await helperPredatesItsBinary() }
        if stale, !didAttemptHelperRecovery {
            didAttemptHelperRecovery = true
            if version > 0 {
                // New enough to retire itself: launchd relaunches the current
                // bundle's binary on the next connection, and the user's
                // existing approval is left untouched.
                await requestHelperQuit()
            } else {
                // Too old to even report a version — the only lever left is
                // re-registering the job, which boots the stale one out.
                await reregisterHelperService()
            }
            version = await probeHelperInterfaceVersion()
            stale = version != pendingNetHelperInterfaceVersion
            if !stale { stale = await helperPredatesItsBinary() }
        }
        let ok = !stale
        helperInterfaceOK = ok
        if ok {
            didAttemptHelperRecovery = false
            lastError = nil
        } else {
            helperReady = false
            // Re-registering can land the daemon back in the approval queue —
            // that needs the user to flip a switch, not to retry.
            helperNeedsApproval = service.status == .requiresApproval
            lastError = helperNeedsApproval
                ? "后台服务已更新，请在系统设置 → 通用 → 登录项与扩展中允许 PendingNet"
                : "后台服务是旧版本且没能自动更新，请退出并重新打开 PendingNet；仍然如此的话，在系统设置 → 通用 → 登录项与扩展里把 PendingNet 关掉再打开"
        }
        return ok
    }

    /// The running helper's interface version, or -1 when it can't tell us —
    /// which is itself the answer for helpers predating `interfaceVersion`,
    /// since they drop the message and tear the connection down.
    private func probeHelperInterfaceVersion() async -> Int {
        await withHelper(-1, timeout: Self.quickTimeout) { p, reply in
            p.interfaceVersion { reply($0) }
        }
    }

    /// Whether the running helper started before the helper binary now sitting
    /// in this app bundle was written — i.e. it cannot be running that binary.
    ///
    /// `ditto` preserves mtimes, so the installed binary carries its build time
    /// and a daemon that predates it is by definition a leftover. Returns false
    /// when either timestamp is unavailable, so an unreadable bundle can never
    /// send the app into a pointless replacement loop.
    private func helperPredatesItsBinary() async -> Bool {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/PendingNetHelper")
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: binary.path),
              let built = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return false }
        let started = await withHelper(0.0, timeout: Self.quickTimeout) { p, reply in
            p.startedAt { reply($0) }
        }
        guard started > 0 else { return false }
        return started < built
    }

    private func requestHelperQuit() async {
        let conn = xpcConnection()
        (conn.remoteObjectProxyWithErrorHandler { _ in } as? HelperProtocol)?.quitForUpgrade()
        dropConnection()
        conn.invalidate()
        // Let launchd reap the exiting daemon before the next connect, or it
        // may hand back the process that is already on its way out.
        try? await Task.sleep(for: .milliseconds(600))
    }

    private func reregisterHelperService() async {
        // Capture before `dropConnection` clears it, or the stale connection is
        // never actually torn down.
        let stale = connection
        dropConnection()
        stale?.invalidate()
        try? await service.unregister()
        // `unregister()` reports success as soon as the job is booted out, but
        // Background Task Management is still retiring the record behind it
        // ("remove succeeded (EINPROGRESS)"). Registering into that window
        // fails and leaves the daemon unregistered altogether — strictly worse
        // than the stale helper we started with. So wait for the removal to
        // land, then retry a few times before giving up.
        for _ in 0..<20 {
            if service.status == .notRegistered { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            do {
                try service.register()
                break
            } catch {
                // Surfaced rather than swallowed: this is the one step that can
                // leave the user with no daemon at all, so it must not fail
                // silently the way it did before.
                lastError = "重新注册后台服务失败：\(error.localizedDescription)"
            }
        }
        helperNeedsApproval = service.status == .requiresApproval
        if service.status != .notRegistered { lastError = nil }
    }

    func registerHelper() {
        Task {
            // A fresh authorization attempt starts from a clean slate — the
            // previous attempt's error must not outlive it.
            lastError = nil
            // Pressing 授权 is the user's explicit retry, so let recovery run
            // again even if an earlier attempt this session gave up.
            didAttemptHelperRecovery = false
            helperInterfaceOK = nil
            do {
                // An already-approved helper must be left alone: unregistering
                // it here knocked it back to 「待批准」, so pressing 授权 made
                // things strictly worse. It may still be a leftover build
                // though, so it has to clear the version handshake.
                if service.status == .enabled {
                    helperNeedsApproval = false
                    guard await ensureHelperCompatible() else { return }
                    helperReady = true
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

    /// Remembers that the daemon reached `.enabled` at least once, so a later
    /// `.notRegistered` can be told apart from a user who never authorized it.
    private static let everEnabledKey = "PendingNetHelperWasEnabled"
    private var didRestoreRegistration = false

    /// Re-registers a daemon that the user had already approved but that is now
    /// gone from Service Management — the state a failed re-registration leaves
    /// behind. Restoring consent the user already gave is fair game; asking for
    /// it in the first place is not, so a daemon that was never enabled is left
    /// alone for the 授权 button to handle.
    private func restoreLostRegistrationIfNeeded() async {
        guard !didRestoreRegistration,
              service.status == .notRegistered,
              UserDefaults.standard.bool(forKey: Self.everEnabledKey) else { return }
        didRestoreRegistration = true
        try? service.register()
    }

    func refresh() async {
        await restoreLostRegistrationIfNeeded()
        let wasReady = helperReady
        helperReady = service.status == .enabled
        helperNeedsApproval = service.status == .requiresApproval
        if helperReady { UserDefaults.standard.set(true, forKey: Self.everEnabledKey) }
        if helperReady, !wasReady {
            // The helper just became approved — whatever failed while it
            // wasn't no longer describes the current state.
            lastError = nil
        }
        if helperReady {
            // A helper-owned system proxy with no engine behind it leaves the
            // whole machine unable to reach anything — clean it up on sight.
            _ = await withCompatibleHelper(false, timeout: Self.quickTimeout) { p, reply in
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
        await withCompatibleHelper(nil, timeout: Self.quickTimeout) { p, reply in
            p.status { run, mode, tail in reply((run, mode, tail)) }
        }
    }

    private func call(_ f: @escaping (HelperProtocol, @escaping (String?) -> Void) -> Void) async {
        let err: String? = await withCompatibleHelper("助手连接失败", timeout: Self.engineTimeout) { p, reply in
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
            // Switching away from a helper-owned mode has to go through the
            // helper, not just flip the GUI's own flag: only the helper can
            // turn the system proxy back off and record the new mode. Skipping
            // it left both behind — the machine still proxied through a port
            // the app no longer runs, and the helper's mode file still said
            // 「sysproxy」, so the next launch adopted that mode and could
            // re-enable the proxy. `running` is the app's view and can be
            // stale, so stop unconditionally rather than only when it is true.
            lastError = nil
            if helperReady {
                await call { p, r in p.stopEngine(reply: r) }
                await call { p, r in p.setTakeover("local", reply: r) }
            }
            takeover = "local"
            running = userEngine.isRunning
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
        let err: String? = await withCompatibleHelper("特权助手尚未就绪", timeout: Self.engineTimeout) { p, reply in
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
