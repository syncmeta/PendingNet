import Foundation
import SBTallyCore

/// Captured at launch so the app can tell whether this process predates the
/// helper binary currently sitting in the app bundle.
let helperStartTime = Date().timeIntervalSince1970
let ETC = "/usr/local/etc/sbtally"
let LABEL = "system/io.sbtally.singbox"
let SYSTEM_PROXY_OWNER = "\(ETC)/pendingnet-system-proxy-owned"
let ACTIVE_SELECTOR = "\(ETC)/pendingnet-active-selector"

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

/// Selects a sing-box outbound through its loopback-only Clash API. The
/// helper reads the API secret from the active config and never exposes it to
/// the app or a process argument.
func selectProxy(configData: Data, selector: String, name: String) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
          let experimental = root["experimental"] as? [String: Any],
          let clashAPI = experimental["clash_api"] as? [String: Any],
          let controller = clashAPI["external_controller"] as? String,
          let url = URL(string: "http://\(controller)/proxies/\(selector)"),
          url.scheme == "http",
          url.host == "127.0.0.1" || url.host == "localhost" else {
        return "本机 sing-box 控制接口配置无效"
    }
    let secret = clashAPI["secret"] as? String ?? ""
    guard let body = try? JSONSerialization.data(withJSONObject: ["name": name]) else {
        return "无法生成 VPS 选择请求"
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 0.5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    for _ in 0..<30 {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var requestError: Error?
        session.dataTask(with: request) { _, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            requestError = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        if statusCode == 204 || statusCode == 200 { return nil }
        if statusCode == 401 { return "本机 sing-box 控制接口凭据不匹配" }
        if requestError == nil, let statusCode {
            return "本机 sing-box 拒绝选择 VPS（HTTP \(statusCode)）"
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return "本机 sing-box 控制接口尚未就绪"
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
        if let error = launchctl(["kickstart", "-k", LABEL]) { return reply(error) }
        guard waitForEngine() else { return reply("sing-box 重启后未进入运行状态") }
        if mode == "sysproxy" { enableOwnedSystemProxy() }
        reply(nil)
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
                    if let error = launchctl(["kickstart", "-k", LABEL]) {
                        throw NSError(domain: "PendingNetHelper", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: error])
                    }
                    guard waitForEngine() else {
                        throw NSError(domain: "PendingNetHelper", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "sing-box 重启后未进入运行状态"])
                    }
                    if let error = activatePendingSelector(configData: active) {
                        throw NSError(domain: "PendingNetHelper", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: error])
                    }
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
                if wasRunning { _ = launchctl(["kickstart", "-k", LABEL]) }
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

let delegate = Helper()
retireLegacyHelperJob()
let listener = NSXPCListener(machServiceName: PendingNetIdentifiers.helper)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
