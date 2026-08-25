import Darwin
import Foundation
import SBTallyCore
import SystemConfiguration

/// TUN / 系统代理下的统计采集器。
///
/// 这两种接管方式的 sing-box 是这个 daemon 用 root 起的，它的 Clash API 密钥
/// 按设计不交给 App（见 `clashRequest` 那段注释）—— 所以采集器也只能由这里起，
/// 和路由模式请助手代劳（`setRouteMode`）是同一条路子。
///
/// 三件事是有意为之，每一件都对应一个会翻车的地方：
///
/// 1. **降到登录用户身份跑**。统计库在用户目录里，三种接管方式共用同一个库
///    （切一次模式统计不该清零）。root 建出来的库和它的 -wal/-shm 会是 root
///    所有，之后「仅端口」模式下 App 起的那份采集器就再也写不进去 —— 而且是
///    静默写不进去。
/// 2. **密钥走管子**。不落磁盘、不上命令行、不进环境变量。
/// 3. **同一根管子当命脉**。写端一关，采集器自己退场；助手被 SIGKILL 也一样。
///    没有这条，中间那层 sudo 一旦不是 exec 直通，就会留下一个还占着统计端口的
///    孤儿，下一次谁都起不来。
final class StatsCollector {
    /// 采集器自己的日志。用户身份写不了 /var/log，所以这份由助手先建好、属主给
    /// 登录用户。
    static let logPath = "/var/log/pendingnet-stats.log"

    private let queue = DispatchQueue(label: "com.pendingname.pendingnet.helper.stats")
    private var process: Process?
    private var lifeline: FileHandle?
    private var failureText: String?
    /// 最近一次请求这个助手干活的那个用户。采集器就降到它身上跑。
    private var requestedByUID: uid_t?

    /// XPC 接进来时记一次：这才是「现在在用这台机器的人」，比控制台用户更准。
    func noteCaller(uid: uid_t) {
        queue.sync { if uid != 0 { requestedByUID = uid } }
    }

    func snapshot() -> (running: Bool, port: Int, failure: String?) {
        queue.sync {
            let alive = process?.isRunning == true
            if !alive, failureText == nil, process != nil {
                failureText = "统计采集器意外退出了，详见 \(Self.logPath)。"
            }
            return (alive, PendingNetStatsService.defaultPort, alive ? nil : failureText)
        }
    }

    /// 起采集器。已经在跑就什么都不做（幂等）。
    ///
    /// 失败只记下原因 —— 代理本身照常可用，统计起不来不该把引擎那条路拖下水。
    func start(configData: Data) {
        queue.sync { startLocked(configData: configData) }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    /// 引擎换了配置（也就可能换了控制端点或密钥）之后重来一遍。
    func restart(configData: Data) {
        queue.sync {
            stopLocked()
            startLocked(configData: configData)
        }
    }

    // MARK: - 干活的那一半（全在 queue 上）

    private func startLocked(configData: Data) {
        if process?.isRunning == true { return }
        process = nil
        failureText = nil

        guard let endpoint = PendingNetClashEndpoint(configData: configData) else {
            failureText = "读不到本机 sing-box 的控制接口配置，统计连不上引擎。"
            return
        }
        guard !endpoint.secret.isEmpty else {
            failureText = "本机 sing-box 配置里没有控制密钥，统计连不上引擎。"
            return
        }
        guard let binary = binaryPath() else {
            failureText = "这个 PendingNet 版本里没有统计程序（sbtally），重新安装一次 App 就会带上它。"
            return
        }
        guard let user = targetUser() else {
            failureText = "还没有用户登录这台机器，统计要等登录之后才起得来。"
            return
        }

        retireLegacyAgent(uid: user.uid, home: user.home)
        guard waitForStatsPortToFree() else {
            let port = PendingNetStatsService.defaultPort
            failureText = "统计端口 \(port) 被别的程序占着。"
                + "腾出它再断开重连一次（查是谁占的：lsof -nP -iTCP:\(port) -sTCP:LISTEN）。"
            return
        }

        // 采集器自己降身份（`-drop-to-uid`）。**不要**改成 sudo：sudo 从 1.9.14 起
        // 默认 use_pty，会给命令套一个伪终端并自己当中间人——密钥走 stdin 进来会被
        // 伪终端回显抄进日志，而管子断掉的 EOF 传不到孙子进程，命脉就断了。
        // 详见 internal/dropprivs 的包注释。
        let arguments = PendingNetStatsService.daemonArguments(
            clashAPI: endpoint.controller,
            port: PendingNetStatsService.defaultPort,
            databasePath: PendingNetStatsService.databasePath(home: user.home),
            secret: .standardInput
        ) + ["-drop-to-uid", String(user.uid), "-drop-to-gid", String(user.gid)]
        prepareLogFile(owner: user.uid)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardInput = pipe
        if let log = FileHandle(forWritingAtPath: Self.logPath) {
            _ = try? log.seekToEnd()
            task.standardOutput = log
            task.standardError = log
        }
        do {
            try task.run()
        } catch {
            failureText = "统计采集器起不来：\(error.localizedDescription)"
            return
        }
        // 密钥进管子，管子留着不关 —— 它同时是采集器的命脉。
        let write = pipe.fileHandleForWriting
        do {
            try write.write(contentsOf: Data((endpoint.secret + "\n").utf8))
        } catch {
            failureText = "把控制密钥交给统计采集器时失败：\(error.localizedDescription)"
            task.terminate()
            try? write.close()
            return
        }
        process = task
        lifeline = write
        helperLog("统计采集器已起（用户 \(user.name)，引擎控制口 \(endpoint.controller)，"
            + "统计端口 \(PendingNetStatsService.defaultPort)）")
    }

    private func stopLocked() {
        guard let task = process else {
            lifeline = nil
            return
        }
        // 先断命脉：采集器自己收摊，比信号更干净（中间那层 sudo 不一定转发信号）。
        try? lifeline?.close()
        lifeline = nil
        for _ in 0..<30 where task.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            task.terminate()
            for _ in 0..<20 where task.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        process = nil
        failureText = nil
        helperLog("统计采集器已停")
    }

    // MARK: - 现场

    private func binaryPath() -> String? {
        // 助手自己就在 PendingNet.app/Contents/MacOS 里，采集器是它的邻居。
        // argv[0] 也算一条：launchd 的 BundleProgram 传的是绝对路径，万一
        // Bundle.main 对一个非 bundle 的可执行文件给不出东西，这条还在。
        let siblings = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            CommandLine.arguments.first
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent() },
        ].compactMap { $0?.appendingPathComponent("sbtally").path }
        if let found = siblings.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return ["/usr/local/bin/sbtally", "/opt/homebrew/bin/sbtally"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func targetUser() -> (name: String, uid: uid_t, gid: gid_t, home: String)? {
        if let uid = requestedByUID, let user = userInfo(uid: uid) { return user }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", !name.isEmpty, uid != 0,
              let user = userInfo(uid: uid) else { return nil }
        return user
    }

    private func userInfo(uid: uid_t) -> (name: String, uid: uid_t, gid: gid_t, home: String)? {
        guard let entry = getpwuid(uid) else { return nil }
        let name = String(cString: entry.pointee.pw_name)
        let home = String(cString: entry.pointee.pw_dir)
        guard !name.isEmpty, home.hasPrefix("/"), name != "root", uid != 0 else { return nil }
        return (name, uid, entry.pointee.pw_gid, home)
    }

    /// 老的手工安装留下的用户级 LaunchAgent。它指着旧端口旧密钥、还开机自启，
    /// 留着就是和这份采集器抢同一个 7777 和同一个库。判断在 SBTallyCore 里（有
    /// 单测），和 App 那侧用的是同一份 —— 谁先跑到谁收拾，落点固定所以不会打架。
    private func retireLegacyAgent(uid: uid_t, home: String) {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let plist = PendingNetStatsService.LegacyAgent.plistURL(home: homeURL)
        let target = "gui/\(uid)/\(PendingNetStatsService.LegacyAgent.label)"
        let (printCode, _) = sh(["/bin/launchctl", "print", target])
        let action = PendingNetStatsService.LegacyAgent.plan(
            plistExists: FileManager.default.fileExists(atPath: plist.path),
            isLoaded: printCode == 0,
            home: homeURL
        )
        switch action {
        case .nothingToDo:
            return
        case .bootOut:
            _ = launchctl(["bootout", target])
            helperLog("卸掉了老的 \(PendingNetStatsService.LegacyAgent.label)（没有 plist 要挪）")
        case .bootOutAndArchive(let plist, let archive):
            _ = launchctl(["bootout", target])
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.moveItem(at: plist, to: archive)
            helperLog("接管了老的 \(PendingNetStatsService.LegacyAgent.label)："
                + "已卸载，plist 挪到 \(archive.lastPathComponent)（改回 .plist 即可还原）")
        }
    }

    private func waitForStatsPortToFree() -> Bool {
        for _ in 0..<20 {
            if !Self.isSomethingListening(on: PendingNetStatsService.defaultPort) { return true }
            Thread.sleep(forTimeInterval: 0.1)
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

    /// /var/log 只有 root 写得进去，而采集器跑在用户身份下 —— 先建好再把属主给它，
    /// 否则它的 stdout/stderr 全丢进黑洞，出了事没有任何线索。
    private func prepareLogFile(owner uid: uid_t) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: Self.logPath) {
            manager.createFile(atPath: Self.logPath, contents: nil,
                               attributes: [.posixPermissions: 0o644])
        }
        try? manager.setAttributes([.ownerAccountID: NSNumber(value: uid)],
                                   ofItemAtPath: Self.logPath)
    }
}
