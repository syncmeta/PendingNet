import Darwin
import Foundation
import SBTallyCore

/// 统计接口现在挂在哪个端口。
///
/// `PendingNetLocalAPIProvider` 从前把 7777 写死在自己身上。端口被别的程序占住
/// 时统计服务会挪到隔壁，读的那一侧也得跟着挪 —— 这个盒子就是两边唯一的交接点。
final class PendingNetStatsEndpoint: @unchecked Sendable {
    static let shared = PendingNetStatsEndpoint()
    private let lock = NSLock()
    private var value = PendingNetStatsService.defaultPort

    var port: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

/// App 自己管的那份 `sbtally daemon`。
///
/// 它跟引擎同生命周期：引擎起来它就起，引擎停掉它就停（见
/// `PendingNetUserEngine.start()` / `stop()`）。二进制随 App 走，密钥每次从引擎
/// 那份 `control-secret` 现读 —— 判断部分全在 `PendingNetStatsService` 里，
/// 这个类只负责观察现场和照着做。
@MainActor
final class PendingNetStatsDaemon {
    private(set) var state: PendingNetStatsService.DaemonState = .stopped

    private let engineDirectory: URL
    private let fileManager = FileManager.default
    private var process: Process?
    private var logHandle: FileHandle?

    init(engineDirectory: URL) {
        self.engineDirectory = engineDirectory
    }

    var logURL: URL { engineDirectory.appendingPathComponent("sbtally.log") }
    private var secretURL: URL { engineDirectory.appendingPathComponent("control-secret") }

    var isRunning: Bool { process?.isRunning == true }

    /// 起统计服务。已经在跑就什么都不做（幂等）。
    ///
    /// 失败不抛异常 —— 代理本身照常可用，统计起不来只该让统计页说清原因，
    /// 不该把「连接」那条路一起拖下水。
    func start() async {
        if isRunning { return }
        guard let binary = binaryURL() else {
            state = .failed("这个 PendingNet 版本里没有统计程序（sbtally）。重新安装一次 App 就会带上它。")
            return
        }
        guard PendingNetStatsService.readSecret(at: secretURL) != nil else {
            state = .failed("引擎还没有生成控制密钥，统计服务暂时连不上它。等代理连上之后会自动重试。")
            return
        }

        var outcome = await choosePort()
        if case .takeOverLegacy(let port) = outcome {
            retireLegacyAgent()
            // 老的采集器是 launchd 拉起来的，bootout 之后端口不是立刻就还回来。
            if await waitForPortToFree(port) {
                outcome = .use(port)
            } else {
                outcome = await choosePort()
            }
        }

        let port: Int
        switch outcome {
        case .use(let value):
            port = value
        case .takeOverLegacy(let value):
            // 收拾过一轮还是它 —— 别再收第二遍，直接说清楚。
            state = .failed("端口 \(value) 上还有另一个统计服务在跑，PendingNet 没能接管它。")
            return
        case .allOccupied(let candidates):
            state = .failed(
                "端口 \(candidates.first ?? PendingNetStatsService.defaultPort) 被别的程序占用了"
                + "（\(candidates.first ?? 0)–\(candidates.last ?? 0) 也都不空）。"
                + "腾出其中一个端口，再重新连接一次。")
            return
        }

        do {
            try launch(binary: binary, port: port)
        } catch {
            state = .failed("统计服务启动失败：\(error.localizedDescription)")
            return
        }

        if await waitUntilAnswering(port: port) {
            PendingNetStatsEndpoint.shared.port = port
            state = .running(port: port)
            return
        }
        let tail = logTail()
        await stop()
        state = .failed(tail.isEmpty ? "统计服务起来了但没有响应，请重新连接一次。" : tail)
    }

    func stop() async {
        defer { state = .stopped }
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

    /// App 退出那一下没有 await 可用，只能同步发信号。
    func stopImmediately() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        state = .stopped
    }

    func logTail() -> String {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return "" }
        return String(decoding: data.suffix(8_000), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(4)
            .joined(separator: "\n")
    }

    // MARK: - 起进程

    private func launch(binary: URL, port: Int) throws {
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let newProcess = Process()
        newProcess.executableURL = binary
        newProcess.arguments = [
            "daemon",
            "-clash-api", "127.0.0.1:\(PendingNetUserEngine.controlPort)",
            "-listen", "127.0.0.1:\(port)",
            // 密钥走文件不走环境变量：引擎重新生成之后，采集端不重启也能跟上。
            "-secret-file", secretURL.path,
            // 规则集由 App 自己的下载器管（见 PendingNetRouteRuleSets），
            // 采集端别去碰同一个目录。
            "-ruleset-dir", "",
        ]
        newProcess.standardOutput = handle
        newProcess.standardError = handle
        newProcess.terminationHandler = { _ in try? handle.close() }
        do {
            try newProcess.run()
        } catch {
            try? handle.close()
            throw error
        }
        process = newProcess
        logHandle = handle
    }

    /// 统计程序在哪。优先包内那份 —— 它跟着 App 一起签名、一起更新；
    /// `/usr/local/bin` 那份只有做过老手工安装的机器才有，只能当退路。
    private func binaryURL() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "sbtally"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/usr/local/bin/sbtally", "/opt/homebrew/bin/sbtally"]
        where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - 端口

    private func choosePort() async -> PendingNetStatsService.PortOutcome {
        let defaultPort = PendingNetStatsService.defaultPort
        let defaultState = await probeDefaultPort()
        return PendingNetStatsService.choosePort { port in
            if port == defaultPort { return defaultState }
            return Self.isSomethingListening(on: port) ? .foreign : .free
        }
    }

    /// 默认端口上是空的、是另一份 sbtally，还是别人的东西。后两者的处置完全不同，
    /// 所以这里非得问一句 HTTP 才能分清。
    private func probeDefaultPort() async -> PendingNetStatsService.PortState {
        let port = PendingNetStatsService.defaultPort
        guard Self.isSomethingListening(on: port) else { return .free }
        return await answersAsStats(port: port) ? .sbtally : .foreign
    }

    private func answersAsStats(port: Int) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/summary?since=1m"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode(Summary.self, from: data)) != nil
    }

    private func waitForPortToFree(_ port: Int) async -> Bool {
        for _ in 0..<20 {
            if !Self.isSomethingListening(on: port) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func waitUntilAnswering(port: Int) async -> Bool {
        for _ in 0..<30 {
            if process?.isRunning != true { return false }
            if await answersAsStats(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func isSomethingListening(on port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    // MARK: - 老残留

    /// 收拾掉 `deploy/install.sh` 那条手工安装路径留下的用户级 LaunchAgent。
    ///
    /// 它指着旧的 Clash 端口和旧密钥，还开机自启 —— 留着就是和 App 自己管的这份
    /// 抢同一个 7777、同一个 SQLite 库。plist 不删只挪（改成不带 .plist 后缀的
    /// 名字，launchd 不再收它），一条 `mv` 就能还原。挪两遍是同一个落点，重复
    /// 执行不会堆出第二份备份。
    private func retireLegacyAgent() {
        let home = fileManager.homeDirectoryForCurrentUser
        let plist = PendingNetStatsService.LegacyAgent.plistURL(home: home)
        let action = PendingNetStatsService.LegacyAgent.plan(
            plistExists: fileManager.fileExists(atPath: plist.path),
            isLoaded: legacyAgentIsLoaded(),
            home: home
        )
        switch action {
        case .nothingToDo:
            return
        case .bootOut:
            bootOutLegacyAgent()
        case .bootOutAndArchive(let plist, let archive):
            bootOutLegacyAgent()
            try? fileManager.removeItem(at: archive)
            try? fileManager.moveItem(at: plist, to: archive)
        }
    }

    private var legacyAgentDomainTarget: String {
        "gui/\(getuid())/\(PendingNetStatsService.LegacyAgent.label)"
    }

    private func legacyAgentIsLoaded() -> Bool {
        launchctl(["print", legacyAgentDomainTarget]) == 0
    }

    private func bootOutLegacyAgent() {
        _ = launchctl(["bootout", legacyAgentDomainTarget])
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
        } catch {
            return -1
        }
        // 先把管子抽干再等退出：`launchctl print` 的输出能撑爆管道缓冲区。
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
