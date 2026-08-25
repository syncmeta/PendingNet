import Foundation
import SBTallyCore
import ServiceManagement
import SwiftUI

/// 让后台服务切路由模式的结果。
///
/// 「够不着后台服务」和「后台服务不肯切」要分开：前者是授权 / 版本的问题，
/// 后者是引擎的问题，界面上该说的话完全不同——从前这两种情形都被糊成一句
/// 「已记住」，用户既不知道为什么没生效，也不知道该做什么。
enum PendingNetRouteModeOutcome: Sendable, Equatable {
    /// 引擎已经按这个模式走了。
    case applied
    /// 连不上后台服务（没授权、旧版、没响应）。
    case unreachable(String)
    /// 后台服务收到了，但没切成，带着它给的理由。
    case rejected(String)
}

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
    /// 统计服务这一侧的状态。统计页面要靠它把「引擎没跑」「统计起不来」
    /// 「真的没流量」分开说，不能再一律「尚未启用」。
    @Published private(set) var statsDaemon: PendingNetStatsService.DaemonState = .stopped

    private let service = SMAppService.daemon(plistName: PendingNetIdentifiers.helperPlistName)
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

    /// 把「仅端口」那份引擎的现状抄进已发布的属性里。统计服务的状态和引擎的
    /// 一起抄 —— 两者同生命周期，分两处更新迟早会有一处忘了。
    private func adoptLocalEngineState() {
        running = userEngine.isRunning
        logTail = userEngine.logTail()
        statsDaemon = userEngine.statsDaemon.currentState()
    }

    init() {
        localProxyPort = userEngine.proxyPort
        allowsLAN = userEngine.allowsLAN
    }

    /// 把原始 `lastError` 翻成用户能照着做的一句话。连接页和菜单栏都靠它--
    /// 错误现在以 toast 弹出，不再常驻在卡片里，所以这份"人话"要在推送 toast
    /// 的地方（应用根层，不分当前在哪个分区）也能取到，不能只活在某个视图的
    /// 计算属性里。
    func friendlyErrorText() -> String? {
        guard let error = lastError else { return nil }
        if error.localizedCaseInsensitiveContains("operation not permitted") {
            // Pending approval is the common case; a leftover legacy
            // registration is only plausible once approval is done.
            if helperNeedsApproval {
                return "请在系统设置 -> 通用 -> 登录项与扩展中允许 PendingNet 后台项目。"
            }
            return "旧版后台服务仍在系统中。请先在系统设置里关闭 PendingNet 后台项目，再回来重新授权。"
        }
        if error.localizedCaseInsensitiveContains("could not connect") ||
            error.localizedCaseInsensitiveContains("助手连接失败") {
            return "后台服务尚未连接，请重新授权。"
        }
        return error
    }

    /// 改端口 / 局域网访问。返回 nil 表示成功，否则是给用户看的人话。
    /// 引擎在跑的话会就地重启到新配置，不用用户自己去关了再开。
    func setLocalInbound(port: Int, allowLAN: Bool) async -> String? {
        do {
            try await userEngine.setLocalInbound(port: port, allowLAN: allowLAN)
            localProxyPort = userEngine.proxyPort
            allowsLAN = userEngine.allowsLAN
            adoptLocalEngineState()
            return nil
        } catch {
            localProxyPort = userEngine.proxyPort
            allowsLAN = userEngine.allowsLAN
            adoptLocalEngineState()
            return error.localizedDescription
        }
    }

    /// 每一份规则集在不在本机。设置页按份显示，切分流档位也吃这份判断。
    @Published private(set) var ruleSetPresence: [String: Bool] = [:]

    /// 照磁盘重算一遍规则集状态。下载完、设置页出现时叫一次。
    func refreshRuleSetPresence() {
        ruleSetPresence = userEngine.ruleSets.presence
    }

    /// 设置页那个「下载 / 重新下载」。引擎在跑就借道本机代理下载——需要这几份
    /// 名单的机器，多半正是没有它们就上不了 GitHub 的那种。
    /// 返回 nil 表示成功，否则是给用户看的人话。
    func refreshRuleSets() async -> String? {
        let failure = await userEngine.ruleSets.refresh(
            throughLocalProxyPort: running ? localProxyPort : nil
        )
        refreshRuleSetPresence()
        return failure
    }

    /// Whether the app-run engine's config declares this exact list mode. Only
    /// meaningful in 「仅端口」 — the helper runs its own config.
    func listModeAvailable(_ name: String) -> Bool {
        guard let mode = routeMode(named: name) else { return false }
        return userEngine.configDeclaresListMode(mode)
    }

    /// Fetches the geosite/geoip lists and rewrites the config to route by them,
    /// restarting the engine if it was up. Returns whether the list modes exist
    /// afterwards.
    func enableListMode(_ name: String) async -> Bool {
        guard let mode = routeMode(named: name) else { return false }
        let ok = await userEngine.enableListMode(mode)
        adoptLocalEngineState()
        refreshRuleSetPresence()
        return ok
    }

    private func routeMode(named name: String) -> PendingNetRouteMode? {
        switch name {
        case "Whitelist": .whitelist
        case "Blacklist": .blacklist
        default: nil
        }
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
        let c = NSXPCConnection(machServiceName: PendingNetIdentifiers.helper,
                                 options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Pin the far end to a helper signed like this app. Without it the app
        // would talk to whatever claims the Mach service name.
        c.setCodeSigningRequirement(
            pendingNetCodeRequirement(identifier: PendingNetIdentifiers.helper))
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
            adoptLocalEngineState()
            return
        }
        // 系统代理 / TUN 下采集器归特权助手管（那份引擎的控制密钥不出助手），
        // 统计接口固定在默认端口 —— 上一轮「仅端口」若挪过端口，这里要挪回来。
        PendingNetStatsEndpoint.shared.port = PendingNetStatsService.defaultPort
        guard helperReady else {
            running = false
            statsDaemon = .stopped
            return
        }
        guard let result = await helperStatus() else { return }
        running = result.0
        takeover = result.1
        logTail = result.2
        statsDaemon = await helperStatsState()
    }

    /// 助手那侧采集器的状态。够不着助手（旧版、没响应）不当成「没有统计」——
    /// 那是助手的问题，说清楚是它。
    private func helperStatsState() async -> PendingNetStatsService.DaemonState {
        let unreachable = PendingNetStatsService.DaemonState.failed(
            "后台服务还不是这一版，统计要等它更新。退出 PendingNet 再打开一次；"
            + "还不行就在设置里重新授权后台服务。")
        return await withCompatibleHelper(unreachable, timeout: Self.quickTimeout) { p, reply in
            p.statsStatus { running, port, failure in
                if running {
                    PendingNetStatsEndpoint.shared.port = port
                    return reply(.running(port: port))
                }
                reply(failure.map { .failed($0) } ?? .stopped)
            }
        }
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
                adoptLocalEngineState()
                running = true
                lastError = nil
                startFailed = false
            } catch {
                adoptLocalEngineState()
                running = false
                lastError = error.localizedDescription
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
            adoptLocalEngineState()
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
            adoptLocalEngineState()
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
        // 无条件停，不看 `running`：那是 app 这边的看法，可能是旧的，而这一侧
        // 只要还有采集器活着，助手那份就抢不到统计端口。stop 本身是幂等的。
        if takeover == "local" { await userEngine.stop() }
        takeover = mode
        await call { p, r in p.setTakeover(mode, reply: r) }
    }

    /// 在 TUN / 系统代理下切路由模式。
    ///
    /// 这两种接管方式的 sing-box 是后台服务用 root 另起的，控制口的 secret
    /// app 看不到，所以只能请它代劳。「仅端口」不走这里 —— 那份引擎是 app
    /// 自己拉起来的，直接 PATCH 它的控制口就行（见 `AppState.pushMode`）。
    func setRouteMode(_ mode: String) async -> PendingNetRouteModeOutcome {
        guard helperReady else {
            return .unreachable(lastError ?? "后台服务还没授权")
        }
        // 版本握手是硬要求：这个方法是 interface version 4 才有的，直接发给
        // 可能是旧版的助手会让 XPC 把整条连接拆掉。
        let outcome = await withCompatibleHelper(
            PendingNetRouteModeOutcome.unreachable(""), timeout: Self.engineTimeout
        ) { p, reply in
            p.setRouteMode(mode) { reply($0.map { .rejected($0) } ?? .applied) }
        }
        // 拿到的是兜底值 —— 真正的原因（旧版助手 / 没响应 / XPC 报错）在这期间
        // 已经被写进 lastError 了。
        if case .unreachable = outcome {
            return .unreachable(lastError ?? "后台服务没有响应")
        }
        return outcome
    }

    func applyServerConfiguration(_ runtime: PendingNetRuntimeServer) async -> Bool {
        if takeover == "local" {
            do {
                try await userEngine.apply(runtime)
                adoptLocalEngineState()
                lastError = nil
                return true
            } catch {
                adoptLocalEngineState()
                lastError = error.localizedDescription
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
