import Foundation
import SBTallyCore
import SystemConfiguration

/// Captured at launch so the app can tell whether this process predates the
/// helper binary currently sitting in the app bundle.
let helperStartTime = Date().timeIntervalSince1970
let ETC = "/usr/local/etc/sbtally"
let LABEL = "system/io.sbtally.singbox"
let SYSTEM_PROXY_OWNER = "\(ETC)/pendingnet-system-proxy-owned"
let ACTIVE_SELECTOR = "\(ETC)/pendingnet-active-selector"
let ROUTE_MODE = "\(ETC)/route-mode"

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run()
    // Drain the pipe BEFORE waiting on exit: readDataToEndOfFile() blocks until EOF
    // (i.e. until the child closes its stdout/stderr, which happens at exit), so this
    // ordering avoids a deadlock where the child blocks writing to a full pipe buffer
    // (>~64KB, e.g. unbounded `launchctl print` output) while the parent blocks in
    // waitUntilExit() without ever draining the pipe.
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}
func launchctl(_ sub: [String]) -> String? {
    let (code, out) = sh(["/bin/launchctl"] + sub)
    return code == 0 ? nil : out
}
/// Boots out the root daemon left behind by the pre-`com.pendingname` builds.
///
/// 0.3.18 and earlier registered `net.pending.PendingNet.helper`. The app's
/// bundle id changed, so this build registers a *different* daemon and the old
/// one is orphaned: launchd keeps it resident, and nothing in the new app can
/// reach it — different Mach service name, and the old helper only accepts peers
/// signed as `net.pending.PendingNet`, which this build no longer is.
///
/// That matters beyond tidiness. Both builds drive the same
/// `/usr/local/etc/sbtally` state, so a stale root daemon can still own the
/// machine's system proxy while the new app believes nothing is set — the exact
/// state where every proxied connection is refused.
///
/// `SMAppService` is no lever here: it only addresses daemons whose plist ships
/// in *this* bundle, and Background Task Management keys the old registration to
/// the old app's code identity. Being root is a lever, so launchd it is. What
/// this cannot do is remove the old app's entry from 「登录项与扩展」 — that
/// record belongs to the old bundle and goes away with it (see
/// docs/macos-updates.md).
///
/// Best-effort on purpose: no such job is the normal case, and a failure here
/// must never keep this helper from coming up.
func retireLegacyHelperJob() {
    let label = "system/" + PendingNetIdentifiers.legacyHelper
    let (code, _) = sh(["/bin/launchctl", "print", label])
    guard code == 0 else { return }
    _ = launchctl(["bootout", label])
}

func networkServices() -> [String] { // active-ish: all listed services minus '*'-disabled
    let (_, out) = sh(["/usr/sbin/networksetup", "-listallnetworkservices"])
    return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
}
/// The port the currently active config actually listens on for proxied
/// traffic. Hard-coding 2080 here meant the system proxy could be pointed at a
/// port nothing was bound to whenever the config used a different one.
func activeProxyPort() -> Int {
    guard let data = try? readData(path: "\(ETC)/master.json"),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let inbounds = root["inbounds"] as? [[String: Any]] else { return 2080 }
    for type in ["mixed", "socks", "http"] {
        if let port = inbounds.first(where: { $0["type"] as? String == type })?["listen_port"] as? Int {
            return port
        }
    }
    return 2080
}

func setSystemProxy(_ on: Bool) {
    let port = String(activeProxyPort())
    for s in networkServices() {
        if on {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxy", s, "127.0.0.1", port])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxy", s, "127.0.0.1", port])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxy", s, "127.0.0.1", port])
        } else {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxystate", s, "off"])
        }
    }
}
func enableOwnedSystemProxy() {
    setSystemProxy(true)
    FileManager.default.createFile(atPath: SYSTEM_PROXY_OWNER, contents: Data(), attributes: [
        .posixPermissions: 0o600,
    ])
}
func disableOwnedSystemProxy() {
    guard FileManager.default.fileExists(atPath: SYSTEM_PROXY_OWNER) else { return }
    setSystemProxy(false)
    try? FileManager.default.removeItem(atPath: SYSTEM_PROXY_OWNER)
}
func currentMode() -> String {
    (try? String(contentsOfFile: "\(ETC)/mode", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "local"
}
func engineRunning() -> Bool {
    let (code, out) = sh(["/bin/launchctl", "print", LABEL])
    return code == 0 && out.contains("state = running")
}

func singBoxBinary() -> String? {
    ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func validateConfig(_ data: Data, name: String) throws {
    guard let binary = singBoxBinary() else {
        throw NSError(domain: "PendingNetHelper", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "找不到 sing-box 可执行文件"])
    }
    let temporary = URL(fileURLWithPath: ETC)
        .appendingPathComponent(".pendingnet-check-\(UUID().uuidString)-\(name).json")
    try data.write(to: temporary, options: .atomic)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let (code, output) = sh([binary, "check", "-c", temporary.path])
    guard code == 0 else {
        throw NSError(domain: "PendingNetHelper", code: Int(code),
                      userInfo: [NSLocalizedDescriptionKey: "sing-box 配置校验失败：\(output)"])
    }
}

func writeConfig(_ data: Data, path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

func createConfigBackup(_ configs: [String: Data]) throws {
    let directory = "\(ETC)/backups/pendingnet-\(Int(Date().timeIntervalSince1970))"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    for (path, data) in configs {
        let destination = URL(fileURLWithPath: directory)
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

func waitForEngine() -> Bool {
    for _ in 0..<30 {
        if engineRunning() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

/// 引擎当前那个进程的 pid，没有进程在跑就是 nil。
func enginePID() -> Int32? {
    let (code, out) = sh(["/bin/launchctl", "print", LABEL])
    guard code == 0 else { return nil }
    return PendingNetEngineRestart.parsePID(launchctlPrintOutput: out)
}

/// 等 `pid` 这个进程真的消失。
///
/// 看的是进程本身而不是 launchd 的 job 状态：这个 job 是 KeepAlive 的，旧实例一退
/// launchd 可能马上拉一个新的起来，job 状态几乎不落地到「停了」。我们要确认的是
/// 「那个握着 TUN 的进程没了」，`kill(pid, 0)` 正好回答这一句（helper 是 root，
/// 权限不会成为噪音）。
func waitForProcessToExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while kill(pid, 0) == 0 {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: PendingNetEngineRestart.pollInterval)
    }
    return true
}

/// 重启引擎：先请它自己退干净，确认进程没了，再拉新的。
///
/// 这里替掉了原来三处各写一遍的 `launchctl kickstart -k`。`-k` 是 SIGKILL：
/// sing-box 来不及拆自己的 TUN、把系统 DNS 和路由还原就没了，launchd 立刻补一个
/// 新实例上来，新实例读到的主链路可能还是空的——引擎日志里那几条
/// `missing default interface` 就是这么来的，进程活着但整机没网。
///
/// 所以改成 SIGTERM + 等它退（超时再 SIGKILL 兜底），退干净了再 kickstart。
/// 返回 nil 表示重启成功。
func restartEngineProcess() -> String? {
    if let running = enginePID() {
        if let error = launchctl(["kill", "SIGTERM", LABEL]) {
            helperLog("请引擎优雅退出失败（\(error)），直接 SIGKILL 兜底")
            _ = launchctl(["kill", "SIGKILL", LABEL])
        }
        if !waitForProcessToExit(running, timeout: PendingNetEngineRestart.gracefulStopTimeout) {
            helperLog("引擎 \(Int(PendingNetEngineRestart.gracefulStopTimeout)) 秒内没有退出，SIGKILL 兜底")
            _ = launchctl(["kill", "SIGKILL", LABEL])
            guard waitForProcessToExit(
                running, timeout: PendingNetEngineRestart.forcedStopTimeout) else {
                return "sing-box 进程 \(running) 杀不掉"
            }
        }
    }
    if let error = launchctl(["kickstart", LABEL]) {
        // KeepAlive 可能已经替我们把新实例拉起来了；那种情况下 kickstart 报什么都无所谓。
        guard !engineRunning() else {
            helperLog("kickstart 报了「\(error)」，但引擎已经在跑，按成功处理")
            return nil
        }
        return error
    }
    return nil
}

/// 一个文件现在多少字节，读不到就是 0。
func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?
        .intValue ?? 0
}

/// 引擎日志从 `offset` 之后新写进去的那一段。
func engineLogWritten(since offset: Int) -> String {
    let current = fileSize(ENGINE_LOG)
    let start = PendingNetEngineHealth.tailOffset(previousSize: offset, currentSize: current)
    guard let handle = FileHandle(forReadingAtPath: ENGINE_LOG) else { return "" }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return "" }
    let data = (try? handle.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 重启引擎，并确认新实例真的绑上了网卡；没绑上就再来一次（最多两次）。
///
/// launchd 报 running 只说明进程还在。系统那会儿如果还没有默认路由，sing-box 的
/// `auto_detect_interface` 就绑不到网卡，日志里吐 `missing default interface`——
/// 进程活着，整机没网。判据和重试预算都在 `PendingNetEngineHealth` 里，有单测；
/// 这里只负责取日志、睡觉、再踢一脚，每一步都写进 helper 日志。
///
/// `context` 是写进日志的那个称呼（谁要求的这次重启）。返回 nil 表示引擎在跑；
/// 补救到头还是绑不上时也返回 nil —— 引擎确实起来了，而这时候把 VPS 配置回滚掉
/// 只会让事情更糟，留一行日志给人看更实在。
func restartEngine(context: String) -> String? {
    var retries = 0
    while true {
        let before = fileSize(ENGINE_LOG)
        if let error = restartEngineProcess() { return error }
        guard waitForEngine() else { return "sing-box 重启后未进入运行状态" }
        Thread.sleep(forTimeInterval: PendingNetEngineHealth.defaultSettleDelay)
        switch PendingNetEngineHealth.verdict(
            freshLog: engineLogWritten(since: before), retriesSoFar: retries
        ) {
        case .healthy:
            return nil
        case .retry(let attempt, let after):
            helperLog("\(context)：引擎起来了却绑不到网卡（\(PendingNetEngineHealth.unboundInterfaceMarker)），"
                + "\(Int(after)) 秒后重启第 \(attempt) 次")
            Thread.sleep(forTimeInterval: after)
            retries = attempt
        case .giveUp(let restarts):
            helperLog("\(context)：连着重启 \(restarts) 次，引擎仍然绑不到网卡，不再重试——"
                + "引擎在跑，但这台机器现在可能没有外网")
            return nil
        }
    }
}

/// What the engine's Clash API said, or why it could not be asked at all.
enum ClashResponse {
    case answered(status: Int, body: Data)
    /// 给用户看的人话。
    case unreachable(String)
}

/// One request to the loopback-only Clash API of the engine this daemon runs,
/// retried until the control port answers (it comes up a moment after launchd
/// reports the job running).
///
/// The API secret is read from the active config here and never handed to the
/// app or put on a command line.
func clashRequest(
    configData: Data,
    method: String,
    path: String,
    body: Data?
) -> ClashResponse {
    guard let endpoint = PendingNetClashEndpoint(configData: configData),
          let url = endpoint.url(path: path) else {
        return .unreachable("本机 sing-box 控制接口配置无效")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 0.5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    for _ in 0..<30 {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.secret.isEmpty {
            request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var responseBody = Data()
        session.dataTask(with: request) { data, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            responseBody = data ?? Data()
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        // No status code at all means nothing answered yet — that is the case
        // worth retrying; anything the engine actually said is the answer.
        if statusCode == 401 { return .unreachable("本机 sing-box 控制接口凭据不匹配") }
        if let statusCode { return .answered(status: statusCode, body: responseBody) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return .unreachable("本机 sing-box 控制接口尚未就绪")
}

/// Selects a sing-box outbound through its Clash API.
func selectProxy(configData: Data, selector: String, name: String) -> String? {
    guard let body = try? JSONSerialization.data(withJSONObject: ["name": name]) else {
        return "无法生成 VPS 选择请求"
    }
    switch clashRequest(configData: configData, method: "PUT",
                        path: "proxies/\(selector)", body: body) {
    case .unreachable(let message):
        return message
    case .answered(let status, _):
        guard status == 200 || status == 204 else {
            return "本机 sing-box 拒绝选择 VPS（HTTP \(status)）"
        }
        return nil
    }
}

/// Switches the running engine's routing mode through its Clash API.
///
/// Two things have to be checked that the API itself will not check: the config
/// has to declare the mode (a `clash_mode` route rule naming it), and the
/// engine has to actually be in it afterwards. Without both, an accepted-then-
/// ignored switch leaves the GUI highlighting 全局 while traffic still follows
/// the whitelist.
func applyRouteMode(_ name: String, configData: Data) -> String? {
    guard let mode = PendingNetRouteMode.clashNamed(name) else {
        return "不认识的路由模式：\(name)"
    }
    let declared = PendingNetClashControl.declaredModes(in: configData)
    guard declared.contains(mode) else {
        return "当前配置里没有「\(name)」这一档路由规则"
    }
    guard let body = try? JSONSerialization.data(withJSONObject: ["mode": mode.clashName]) else {
        return "无法生成路由模式请求"
    }
    switch clashRequest(configData: configData, method: "PATCH", path: "configs", body: body) {
    case .unreachable(let message):
        return message
    case .answered(let status, _):
        guard status == 200 || status == 204 else {
            return "本机 sing-box 拒绝切换路由模式（HTTP \(status)）"
        }
    }
    switch clashRequest(configData: configData, method: "GET", path: "configs", body: nil) {
    case .unreachable(let message):
        return message
    case .answered(let status, let responseBody):
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let current = root["mode"] as? String else {
            return "无法确认本机 sing-box 的路由模式"
        }
        guard PendingNetRouteMode.clashNamed(current) == mode else {
            return "本机 sing-box 没有切到「\(name)」（仍然是 \(current)）"
        }
        return nil
    }
}

/// The route mode the user last picked, as recorded by `setRouteMode`.
func storedRouteMode() -> PendingNetRouteMode? {
    guard let raw = try? String(contentsOfFile: ROUTE_MODE, encoding: .utf8) else { return nil }
    return PendingNetRouteMode.clashNamed(raw.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Re-applies the recorded route mode to an engine that has just come up.
///
/// The config's `default_mode` is `Whitelist` and `store_mode` is off, so every
/// restart — switching takeover, applying a VPS — drops back to the whitelist.
/// Without replaying it here the user's pick is quietly overwritten each time.
///
/// Best-effort on purpose: the engine *is* up, and failing the caller over a
/// mode that did not land would be a worse answer than the mode being stale.
func reapplyStoredRouteMode(configData: Data) {
    guard let mode = storedRouteMode() else { return }
    _ = applyRouteMode(mode.clashName, configData: configData)
}

func activatePendingSelector(configData: Data) -> String? {
    guard let selector = try? String(contentsOfFile: ACTIVE_SELECTOR, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !selector.isEmpty else { return nil }
    return selectProxy(configData: configData, selector: "proxy", name: selector)
}

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func startEngine(reply: @escaping (String?) -> Void) {
        // Invariant: the system proxy is only ever left enabled when the engine
        // is actually running. Every failure path below must therefore tear it
        // down — otherwise the machine is left pointing at a dead port and all
        // proxied traffic fails with "Connection refused".
        func fail(_ message: String?) {
            disableOwnedSystemProxy()
            reply(message)
        }
        _ = launchctl(["bootout", LABEL])   // idempotent
        let err = launchctl(["bootstrap", "system", "/Library/LaunchDaemons/io.sbtally.singbox.plist"])
        guard err == nil else { return fail(err) }
        guard waitForEngine() else { return fail("sing-box 启动后未进入运行状态") }
        let configData = try? readData(path: "\(ETC)/master.json")
        if let configData, let selectionError = activatePendingSelector(configData: configData) {
            return fail(selectionError)
        }
        if let configData { reapplyStoredRouteMode(configData: configData) }
        if currentMode() == "sysproxy" { enableOwnedSystemProxy() }
        reply(nil)
    }
    func stopEngine(reply: @escaping (String?) -> Void) {
        disableOwnedSystemProxy()
        reply(launchctl(["bootout", LABEL]))
    }
    func setTakeover(_ mode: String, reply: @escaping (String?) -> Void) {
        guard ["tun", "sysproxy", "local"].contains(mode) else { return reply("bad mode") }
        let variant = mode == "tun" ? "master-tun.json" : "master-notun.json"
        let wasRunning = engineRunning()
        // Tear the system proxy down FIRST, before anything that can fail or
        // return early. Doing it after the config writes meant a failed write
        // left the machine pointing at a proxy for a takeover mode it was no
        // longer in. Re-enabling below only happens once the engine is up.
        disableOwnedSystemProxy()
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(ETC)/\(variant)"))
            try data.write(to: URL(fileURLWithPath: "\(ETC)/master.json"))
            try mode.write(toFile: "\(ETC)/mode", atomically: true, encoding: .utf8)
        } catch { return reply("\(error)") }
        guard wasRunning else { return reply(nil) }
        if let error = restartEngine(context: "切换接管模式") { return reply(error) }
        if let configData = try? readData(path: "\(ETC)/master.json") {
            reapplyStoredRouteMode(configData: configData)
        }
        if mode == "sysproxy" { enableOwnedSystemProxy() }
        reply(nil)
    }

    /// Switches the engine this daemon runs to `mode`, and records the pick so
    /// it survives the restarts that switching takeover or applying a VPS
    /// cause. Recording happens even with no engine up: the choice is a
    /// preference, and `reapplyStoredRouteMode` lands it at the next start.
    func setRouteMode(_ mode: String, reply: @escaping (String?) -> Void) {
        guard let known = PendingNetRouteMode.clashNamed(mode) else {
            return reply("不认识的路由模式：\(mode)")
        }
        do {
            try writeConfig(Data((known.clashName + "\n").utf8), path: ROUTE_MODE)
        } catch {
            return reply("路由模式没能记下来：\(error.localizedDescription)")
        }
        guard engineRunning() else { return reply(nil) }
        guard let configData = try? readData(path: "\(ETC)/master.json") else {
            return reply("读不到本机 sing-box 配置")
        }
        reply(applyRouteMode(known.clashName, configData: configData))
    }

    /// Clears a system proxy this helper owns but that no longer has a live
    /// engine behind it — the state a crashed or half-failed start leaves the
    /// machine in, where every proxied connection is refused.
    func repairSystemProxy(reply: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: SYSTEM_PROXY_OWNER),
              !engineRunning() else { return reply(false) }
        disableOwnedSystemProxy()
        reply(true)
    }
    func applyServerConfiguration(
        _ serverID: String,
        name: String,
        selectorTag: String,
        proxyOutbounds: Data,
        reply: @escaping (String?) -> Void
    ) {
        guard !serverID.isEmpty, !name.isEmpty else {
            return reply("VPS 身份无效")
        }
        let tunPath = "\(ETC)/master-tun.json"
        let noTunPath = "\(ETC)/master-notun.json"
        let masterPath = "\(ETC)/master.json"
        let paths = [tunPath, noTunPath, masterPath]
        do {
            var backups: [String: Data] = [:]
            for path in paths {
                backups[path] = try readData(path: path)
            }
            let runtime = PendingNetRuntimeServer(
                serverID: serverID,
                name: name,
                selectorTag: selectorTag,
                proxyOutbounds: proxyOutbounds
            )
            let newTun = try PendingNetLocalConfigComposer.merge(
                baseConfig: try readData(path: tunPath), runtimeServer: runtime)
            let newNoTun = try PendingNetLocalConfigComposer.merge(
                baseConfig: try readData(path: noTunPath), runtimeServer: runtime)
            try validateConfig(newTun, name: "tun")
            try validateConfig(newNoTun, name: "notun")
            try createConfigBackup(backups)

            let active = currentMode() == "tun" ? newTun : newNoTun
            let wasRunning = engineRunning()
            let previousSelector = try? readData(path: ACTIVE_SELECTOR)
            do {
                try writeConfig(newTun, path: tunPath)
                try writeConfig(newNoTun, path: noTunPath)
                try writeConfig(active, path: masterPath)
                try writeConfig(Data((selectorTag + "\n").utf8), path: ACTIVE_SELECTOR)
                if wasRunning {
                    if let error = restartEngine(context: "应用 VPS 配置") {
                        throw NSError(domain: "PendingNetHelper", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: error])
                    }
                    if let error = activatePendingSelector(configData: active) {
                        throw NSError(domain: "PendingNetHelper", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: error])
                    }
                    reapplyStoredRouteMode(configData: active)
                }
            } catch {
                for path in paths {
                    if let old = backups[path] { try? writeConfig(old, path: path) }
                }
                if let previousSelector {
                    try? writeConfig(previousSelector, path: ACTIVE_SELECTOR)
                } else {
                    try? FileManager.default.removeItem(atPath: ACTIVE_SELECTOR)
                }
                if wasRunning { _ = restartEngine(context: "回滚 VPS 配置") }
                throw error
            }
            reply(nil)
        } catch {
            reply("应用 VPS 配置失败：\(error.localizedDescription)")
        }
    }
    func status(reply: @escaping (Bool, String, String) -> Void) {
        let (_, tail) = sh(["/usr/bin/tail", "-n", "5", "/var/log/sbtally-singbox.log"])
        reply(engineRunning(), currentMode(), tail)
    }

    func interfaceVersion(reply: @escaping (Int) -> Void) {
        reply(pendingNetHelperInterfaceVersion)
    }

    func startedAt(reply: @escaping (Double) -> Void) {
        reply(helperStartTime)
    }

    /// Exits so launchd relaunches this job from the app bundle currently on
    /// disk. Replacing the app leaves the previously launched helper resident
    /// and serving its old code forever; this is how a newly installed app
    /// retires it without the user having to re-approve anything.
    ///
    /// The reply is the caller's own connection tearing down, so drain briefly
    /// first and let the exit happen off the incoming message's thread.
    func quitForUpgrade() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exit(0) }
    }

    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // This daemon runs as root and every method on it reconfigures the
        // machine's networking, so an unauthenticated listener let any process
        // on the box drive it. Only accept a peer signed like we are.
        let requirement = pendingNetCodeRequirement(identifier: PendingNetIdentifiers.app)
        guard pendingNetProcessSatisfies(pid: c.processIdentifier, requirement: requirement) else {
            return false
        }
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
}

func readData(path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

// MARK: - 换网卡自愈 + 日志轮转

let ENGINE_LOG = "/var/log/sbtally-singbox.log"
let HELPER_LOG = "/var/log/pendingnet-helper.log"

/// 这个 daemon 自己的日志。`com.pendingname.pendingnet.helper.plist` 没有
/// `StandardOutPath`，所以 print 出去的东西谁也看不到；写进一个固定文件才拿得到
/// 「为什么重启了引擎」的实证，同时也进统一日志方便 `log show` 捞。
func helperLog(_ message: String) {
    NSLog("PendingNetHelper: %@", message)
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: HELPER_LOG) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        FileManager.default.createFile(
            atPath: HELPER_LOG, contents: data, attributes: [.posixPermissions: 0o644])
    }
}

/// 原地截断一个长到没边的日志，留一代尾巴到 `.1`。
///
/// launchd 只会往 `StandardOutPath` 一路追加，本机那份引擎日志就这么长到了
/// 160MB。不能用 newsyslog：它把文件改名之后 sing-box 手上的 fd 还指着旧
/// inode，而这个 daemon 没有 pidfile 可以让 newsyslog 发信号。launchd 是以
/// `O_APPEND` 打开的，所以 truncate 到 0 之后进程的下一次写入会落回开头，
/// 不留空洞——这是这里唯一安全的做法。
func rotateLogIfNeeded(_ path: String) {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
        as? NSNumber else { return }
    let total = size.intValue
    guard case .rotate(let keep) = PendingNetLogRotation.plan(size: total) else { return }
    guard let handle = FileHandle(forUpdatingAtPath: path) else {
        return helperLog("轮转 \(path) 失败：打不开文件")
    }
    defer { try? handle.close() }
    do {
        try handle.seek(toOffset: UInt64(max(0, total - keep)))
        let tail = handle.readDataToEndOfFile()
        let archive = PendingNetLogRotation.archivePath(for: path)
        try tail.write(to: URL(fileURLWithPath: archive), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: archive)
        try handle.truncate(atOffset: 0)
        helperLog("轮转 \(path)：原 \(total) 字节，末尾 \(tail.count) 字节留到 \(archive)，已原地截断")
    } catch {
        helperLog("轮转 \(path) 失败：\(error.localizedDescription)")
    }
}

/// 盯着系统主链路，换网卡就把引擎踢一下。
///
/// 为什么要有这东西：macOS 上有线切无线之后，sing-box 的 `auto_detect_interface`
/// 不会把出站重新绑到新网卡上——代理腿和 direct 腿一起 `network is unreachable`，
/// 引擎自己永远缓不过来。文档里那套 `network_strategy` / `network_type` 明写着
/// 「只在 Android 和 Apple 平台的图形客户端里支持」，也就是走 NetworkExtension 的
/// 那条路；我们跑的是命令行 daemon，用不上。剩下的路只有从外面重启。
///
/// 所有判断（去抖、节流、中间态、用户停掉的引擎不拉起来）都在
/// `PendingNetLinkWatchdog` 里，有单测；这里只负责取值和执行。
final class LinkSelfHealer {
    private let queue = DispatchQueue(label: "com.pendingname.pendingnet.helper.link")
    private var watchdog = PendingNetLinkWatchdog()
    private var store: SCDynamicStore?
    /// 每次重新约复查都 +1，旧的那次醒来发现号码对不上就自己退场。
    private var wakeGeneration = 0

    func start() {
        queue.async { [self] in
            var context = SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                // SCDynamicStore 的回调派发在下面设的那个队列上，直接干活即可。
                Unmanaged<LinkSelfHealer>.fromOpaque(info).takeUnretainedValue().tick()
            }
            guard let store = SCDynamicStoreCreate(
                nil, "com.pendingname.pendingnet.helper" as CFString, callback, &context)
            else {
                helperLog("订阅主链路变化失败：SCDynamicStoreCreate 返回空，换网卡自愈没启用")
                return
            }
            self.store = store
            SCDynamicStoreSetNotificationKeys(
                store,
                ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
                nil
            )
            SCDynamicStoreSetDispatchQueue(store, queue)
            helperLog("已订阅主链路变化：换网卡后会自动重启引擎（去抖 "
                + "\(Int(PendingNetLinkWatchdog.defaultDebounce))s，节流 "
                + "\(Int(PendingNetLinkWatchdog.defaultThrottle))s）")
            tick()
            maintain()
        }
    }

    /// 只在 `queue` 上调用。
    private func tick() {
        let snapshot = currentSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        switch watchdog.evaluate(
            snapshot: snapshot, engineShouldRun: engineRunning(), at: now
        ) {
        case .idle:
            break
        case .wait(let until):
            wake(after: max(0.2, until - now))
        case .restart(let reason):
            heal(reason: reason)
        }
    }

    private func wake(after delay: TimeInterval) {
        wakeGeneration += 1
        let generation = wakeGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.tick()
        }
    }

    private func heal(reason: String) {
        helperLog("自愈：\(reason)")
        if let error = restartEngine(context: "换网卡自愈") {
            return helperLog("自愈失败：\(error)")
        }
        // 重启等于回到 default_mode，用户选的 VPS 和路由档位要照 startEngine 那样补回来。
        if let configData = try? readData(path: "\(ETC)/master.json") {
            if let error = activatePendingSelector(configData: configData) {
                helperLog("自愈后重选 VPS 失败：\(error)")
            }
            reapplyStoredRouteMode(configData: configData)
        }
        // 新链路可能是这台机器上刚出现的网络服务，代理设置不会自己跟过去。
        if currentMode() == "sysproxy",
           FileManager.default.fileExists(atPath: SYSTEM_PROXY_OWNER) {
            setSystemProxy(true)
        }
        helperLog("自愈完成：引擎已重启")
    }

    /// 每 5 分钟看一眼两份日志有没有长疯。
    private func maintain() {
        rotateLogIfNeeded(ENGINE_LOG)
        rotateLogIfNeeded(HELPER_LOG)
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.maintain() }
    }

    private func currentSnapshot() -> PendingNetLinkSnapshot {
        guard let store else { return PendingNetLinkSnapshot() }
        let global = SCDynamicStoreCopyValue(
            store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        var address: String?
        if let service = global?["PrimaryService"] as? String,
           let ipv4 = SCDynamicStoreCopyValue(
               store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
           let addresses = ipv4["Addresses"] as? [String] {
            address = addresses.first
        }
        return PendingNetLinkSnapshot(
            primaryInterface: global?["PrimaryInterface"] as? String,
            primaryAddress: address,
            router: global?["Router"] as? String
        )
    }
}

let delegate = Helper()
let linkSelfHealer = LinkSelfHealer()
retireLegacyHelperJob()
linkSelfHealer.start()
let listener = NSXPCListener(machServiceName: PendingNetIdentifiers.helper)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
