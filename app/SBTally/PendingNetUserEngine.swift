import Darwin
import Foundation
import SBTallyCore

enum PendingNetUserEngineError: LocalizedError {
    case missingSingBox
    case noConfiguration
    case validationFailed(String)
    case startFailed(String)
    case portOutOfRange
    case portReserved
    case portInUse(Int)

    var errorDescription: String? {
        switch self {
        case .missingSingBox:
            "找不到 sing-box。请先安装 sing-box，或使用包含内置引擎的 PendingNet 版本。"
        case .noConfiguration:
            "还没有可运行的 VPS 配置，请先导入 .pdn 并应用。"
        case .validationFailed(let detail):
            "本机代理配置校验失败：\(detail)"
        case .startFailed(let detail):
            "本机代理启动失败：\(detail)"
        case .portOutOfRange:
            "端口要在 1024 到 65535 之间。"
        case .portReserved:
            "29090 是 PendingNet 自己的控制端口，换一个。"
        case .portInUse(let port):
            "端口 \(port) 已经被别的程序占用了，换一个再试。"
        }
    }
}

@MainActor
final class PendingNetUserEngine {
    nonisolated static let controlURL = URL(string: "http://127.0.0.1:29090")!

    static let portKey = "pendingnet.local-proxy-port"
    static let lanKey = "pendingnet.allow-lan"
    static let defaultProxyPort = 2080

    private(set) var proxyPort: Int
    /// 开着就监听 0.0.0.0，同网段的设备也能用这个代理。
    private(set) var allowsLAN: Bool
    private(set) var process: Process?
    private var logHandle: FileHandle?

    private let fileManager = FileManager.default
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configured = defaults.integer(forKey: Self.portKey)
        proxyPort = (1024...65535).contains(configured) ? configured : Self.defaultProxyPort
        allowsLAN = defaults.bool(forKey: Self.lanKey)
    }

    var listenAddress: String {
        allowsLAN ? PendingNetProxyOnlyConfig.anyListen : PendingNetProxyOnlyConfig.loopbackListen
    }

    /// 改本机入站（端口 / 是否允许局域网）：校验、落盘、改写已应用的配置，
    /// 正在跑就顺手重启。配置里的 VPS 出站原样保留 —— 换个端口不该让用户重新配对。
    func setLocalInbound(port: Int, allowLAN: Bool) async throws {
        guard (1024...65535).contains(port) else { throw PendingNetUserEngineError.portOutOfRange }
        guard port != 29090 else { throw PendingNetUserEngineError.portReserved }
        if port != proxyPort, !portIsFree(port) { throw PendingNetUserEngineError.portInUse(port) }

        let address = allowLAN
            ? PendingNetProxyOnlyConfig.anyListen
            : PendingNetProxyOnlyConfig.loopbackListen
        if fileManager.fileExists(atPath: configURL.path) {
            let updated = try PendingNetProxyOnlyConfig.applyingLocalInbound(
                to: try Data(contentsOf: configURL),
                port: port,
                listenAddress: address
            )
            try validate(updated)
            let wasRunning = isRunning
            if wasRunning { await stop() }
            try updated.write(to: configURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            persist(port: port, allowLAN: allowLAN)
            if wasRunning { try await start() }
            return
        }
        persist(port: port, allowLAN: allowLAN)
    }

    private func persist(port: Int, allowLAN: Bool) {
        proxyPort = port
        allowsLAN = allowLAN
        defaults.set(port, forKey: Self.portKey)
        defaults.set(allowLAN, forKey: Self.lanKey)
    }

    /// Whether nothing else is listening on 127.0.0.1:port right now. A bind
    /// test, not a connect test: a port can be held by a process that refuses
    /// connections and still be unusable for us.
    private func portIsFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    var isRunning: Bool { process?.isRunning == true }

    var configURL: URL { engineDirectory.appendingPathComponent("config.json") }
    var logURL: URL { engineDirectory.appendingPathComponent("sing-box.log") }

    /// Cached geosite/geoip lists — present means 白名单/黑名单 can be declared.
    var ruleSets: PendingNetRouteRuleSets {
        PendingNetRouteRuleSets(
            directory: engineDirectory.appendingPathComponent("rule-sets", isDirectory: true)
        )
    }

    /// Downloads the rule-sets if needed and rewrites the applied config to use
    /// them, restarting the engine when it is already up. Returns whether the
    /// list modes are available afterwards.
    @discardableResult
    func enableListModes() async -> Bool {
        let sets = ruleSets
        guard await sets.download(throughLocalProxyPort: isRunning ? proxyPort : nil),
              let directory = sets.configuredDirectory else { return false }
        guard fileManager.fileExists(atPath: configURL.path) else { return true }
        do {
            let current = try Data(contentsOf: configURL)
            guard PendingNetProxyOnlyConfig.declaredListModes(current) != sets.availableModes else {
                return true
            }
            let updated = try PendingNetProxyOnlyConfig.applyingRouteRules(
                to: current,
                ruleSetDirectory: directory,
                availableRuleSetTags: sets.availableRuleSetTags
            )
            try validate(updated)
            let wasRunning = isRunning
            if wasRunning { await stop() }
            try updated.write(to: configURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            if wasRunning { try await start() }
            return true
        } catch {
            return false
        }
    }

    func apply(_ runtime: PendingNetRuntimeServer) async throws {
        try prepareDirectory()
        let base = try PendingNetProxyOnlyConfig.make(
            controlSecret: try controlSecret(),
            cachePath: engineDirectory.appendingPathComponent("cache.db").path,
            listenPort: proxyPort,
            listenAddress: listenAddress,
            ruleSetDirectory: ruleSets.configuredDirectory,
            availableRuleSetTags: ruleSets.availableRuleSetTags
        )
        let config = try PendingNetLocalConfigComposer.merge(
            baseConfig: base,
            runtimeServer: runtime
        )
        try validate(config)

        let wasRunning = isRunning
        if wasRunning { await stop() }
        try config.write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
        if wasRunning { try await start() }
    }

    func start() async throws {
        if isRunning { return }
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw PendingNetUserEngineError.noConfiguration
        }
        let binary = try singBoxBinary()
        try prepareDirectory()
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let newProcess = Process()
        newProcess.executableURL = binary
        newProcess.arguments = ["run", "-c", configURL.path]
        newProcess.standardOutput = handle
        newProcess.standardError = handle
        newProcess.terminationHandler = { _ in
            try? handle.close()
        }
        do {
            try newProcess.run()
        } catch {
            try? handle.close()
            throw PendingNetUserEngineError.startFailed(error.localizedDescription)
        }
        process = newProcess
        logHandle = handle

        for _ in 0..<30 {
            if !newProcess.isRunning {
                process = nil
                logHandle = nil
                throw PendingNetUserEngineError.startFailed(logTail())
            }
            if await controlIsReady() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await stop()
        throw PendingNetUserEngineError.startFailed(logTail().isEmpty
            ? "控制端口没有响应，请确认 \(proxyPort) 或 29090 未被其它程序占用。"
            : logTail())
    }

    func stop() async {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func stopImmediately() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func logTail() -> String {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return "" }
        return String(decoding: data.suffix(12_000), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12)
            .joined(separator: "\n")
    }

    private var engineDirectory: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PendingNet/engine", isDirectory: true)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: engineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: engineDirectory.path
        )
    }

    private func controlSecret() throws -> String {
        let url = engineDirectory.appendingPathComponent("control-secret")
        if let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try value.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }

    private func singBoxBinary() throws -> URL {
        let bundled = Bundle.main.url(forResource: "sing-box", withExtension: nil)
        let candidates = [bundled?.path, "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
            .compactMap { $0 }
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw PendingNetUserEngineError.missingSingBox
        }
        return URL(fileURLWithPath: path)
    }

    private func validate(_ config: Data) throws {
        let temporary = engineDirectory.appendingPathComponent(".config-check-\(UUID().uuidString).json")
        try config.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }

        let check = Process()
        check.executableURL = try singBoxBinary()
        check.arguments = ["check", "-c", temporary.path]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            throw PendingNetUserEngineError.validationFailed(
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func controlIsReady() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 0.3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.controlURL.appendingPathComponent("version"))
        if let secret = try? controlSecret() {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
