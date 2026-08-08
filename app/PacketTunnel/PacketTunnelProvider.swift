import Foundation
import Libbox
import NetworkExtension
import os
import SBTallyCore

/// PendingNet 的 Packet Tunnel Extension：把 sing-box libbox 内核跑起来。
///
/// 扩展**不联网**：不刷新 `/v1/node`、不下载规则集、没有 HTTP 客户端。
/// 它只读 App Group 里由主 App 写好的本地文件，路径一律取自
/// `PendingNetTunnelPaths`。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(
        subsystem: "com.pendingname.pendingnet.extension",
        category: "Provider"
    )

    private lazy var platformInterface = PendingNetPlatformInterface(self)
    private(set) var commandServer: LibboxCommandServer?
    private var configContent: String?

    override func startTunnel(options startOptions: [String: NSObject]?) async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            // 拿不到容器就没有地方留痕。这是唯一一条 App 侧看不到原文的失败，
            // 也是最不可能发生的一条（App Group 配错了会连不上任何文件）。
            throw PendingNetTunnelError.message("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        // 先把扩展自己的 fd 2 接到文件上，后面所有 writeMessage 才有落点。
        // 这一步不依赖 libbox，放在 LibboxSetup 之前是安全的。
        redirectProcessStderr(base: base)

        // NEVPNConnection 不向 App 传递这里抛出的错误——App 只看得到 status
        // 翻到 .disconnected。不落一份原文，「隧道起不来」在 App 里就是一个
        // 没有任何线索的黑盒。
        do {
            try await bringUp(options: startOptions, base: base)
        } catch {
            recordStartFailure(error, base: base)
            throw error
        }
        clearStartFailure(base: base)
    }

    private func bringUp(options startOptions: [String: NSObject]?, base: URL) async throws {
        let resolved = try resolveConfigContent(options: startOptions, base: base)
        configContent = resolved.content

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = base.path
        setup.tempPath = NSTemporaryDirectory()
        // Packet Tunnel Extension 的内存上限约 50MB，日志缓冲要克制。
        setup.logMaxLines = 500
        setup.debug = false

        var setupError: NSError?
        if !LibboxSetup(setup, &setupError) {
            let reason = setupError?.localizedDescription ?? "未知原因"
            throw PendingNetTunnelError.message("libbox setup 失败：\(reason)")
        }
        // 只能排在 Setup 之后，原因见 redirectGoCrashOutput 的注释。
        redirectGoCrashOutput(base: base)
        // 本版本 libbox（sing-box v1.13.13）没有 SetupOptions.oomKillerEnabled，
        // 内存约束通过这个开关生效：它设置 Go 的软内存上限并收紧 GC。
        // 实测扩展贴顶时 goroutine 栈占近一半内存，这是唯一的兜底。
        LibboxSetMemoryLimit(true)

        var serverError: NSError?
        let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        guard let server else {
            let reason = serverError?.localizedDescription ?? "未知原因"
            throw PendingNetTunnelError.message("创建 command server 失败：\(reason)")
        }
        do {
            try server.start()
        } catch {
            throw PendingNetTunnelError.message(
                "启动 command server 失败：\(error.localizedDescription)"
            )
        }
        commandServer = server

        try await startService()

        // 快照只在内核确实接受了这份配置之后才落盘。反过来写会毒化
        // on-demand 自启：一份被 libbox 拒掉的配置留在快照里，之后每次
        // App 未运行时的自启都会读到它、失败、隧道起不来，直到用户手动
        // 打开 App 为止 —— 而两级配置的存在意义正是为了避免这一幕。
        if resolved.isFromStartOptions {
            persistSnapshot(resolved.content, base: base)
        }
        writeMessage("(packet-tunnel) PendingNet 隧道已就绪")
    }

    private struct ResolvedConfig {
        let content: String
        /// true 表示来自本次 startTunnel 的 options（即尚未落盘的新配置）。
        let isFromStartOptions: Bool
    }

    /// 配置来源两级：优先 startTunnel options，回退持久化快照。
    ///
    /// 系统按 on-demand 规则在 App 未运行时拉起隧道时 options 为空，
    /// 只认 options 会导致自启永远失败；只读文件则拿不到本次启动的新配置。
    private func resolveConfigContent(
        options: [String: NSObject]?,
        base: URL
    ) throws -> ResolvedConfig {
        if let content = options?["configContent"] as? String, !content.isEmpty {
            return ResolvedConfig(content: content, isFromStartOptions: true)
        }
        let snapshot = PendingNetTunnelPaths.snapshotURL(in: base)
        guard let data = try? Data(contentsOf: snapshot),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty
        else {
            throw PendingNetTunnelError.message("没有可用配置，请回到 PendingNet 完成配对")
        }
        if PendingNetTunnelConfig.isRemovedDirectModeSnapshot(data) {
            try? FileManager.default.removeItem(at: snapshot)
            throw PendingNetTunnelError.message("没有可用配置，请回到 PendingNet 完成配对")
        }
        return ResolvedConfig(content: content, isFromStartOptions: false)
    }

    /// 落盘失败不拆隧道：此刻内核已经跑起来了，为了写不成一个文件而把
    /// 一条正常工作的隧道关掉是更坏的结果。代价是下次自启会读到旧配置，
    /// 所以必须留痕。
    private func persistSnapshot(_ content: String, base: URL) {
        do {
            try Data(content.utf8).write(
                to: PendingNetTunnelPaths.snapshotURL(in: base),
                options: .atomic
            )
        } catch {
            writeMessage("(packet-tunnel) 写入配置快照失败，下次自启将沿用旧配置：\(error.localizedDescription)")
        }
    }

    /// 把扩展进程自己的 fd 2 接到 App Group 里的 `stderr.log`。
    ///
    /// **只捕获扩展自身的输出**（`writeMessage` 写的那些诊断行，以及进程里
    /// 任何往 stderr 写的东西），**拿不到 sing-box 的日志**：libbox 一旦拿到
    /// platform interface 就把 `defaultLogWriter` 设成 `io.Discard`，内核日志
    /// 改走 `PlatformLogWriter` 进 command server 的环形缓冲，从不经过
    /// stderr。内核日志的唯一出口是 command client 订阅 `LibboxCommandLog`
    /// （主 App 的 `PendingNetCommandClient`）。
    ///
    /// 用 `"a"` 追加而非 `"w"` 截断：`startTunnel` 失败后系统可能立刻重试，
    /// 截断会把上一轮真正有用的失败现场冲掉。`_IONBF` 是因为我们自己走
    /// `FileHandle`（裸 `write(2)`），留着 stdio 缓冲会让两路写乱序。
    private func redirectProcessStderr(base: URL) {
        let path = PendingNetTunnelPaths.stderrLogURL(in: base).path
        guard freopen(path, "a", stderr) != nil else {
            // 只能走 os.Logger —— 此刻 stderr 和 command server 都还没有。
            Self.logger.error(
                "重定向 stderr 到 \(path, privacy: .public) 失败：errno \(errno, privacy: .public)"
            )
            return
        }
        setvbuf(stderr, nil, _IONBF, 0)
    }

    /// Go 运行时崩溃栈的出口。**只管这一项**。
    ///
    /// 名字有误导性：v1.13.13 的 `RedirectStderr` 并不重定向 fd 2，它是
    /// `os.Create(path)` + `debug.SetCrashOutput(file)` + `Close()`——接管的
    /// 只有 panic traceback。
    ///
    /// 而且它必须排在 `LibboxSetup` **之后**：内部 `Chown` 用的
    /// `sUserID`/`sGroupID` 只在 `Setup()` 里被赋值，提前调用等于
    /// `chown(path, 0, 0)`，在以 mobile 身份运行的沙盒扩展里必然 EPERM，
    /// 而失败路径会 `os.Remove` 掉刚创建的那个文件。
    ///
    /// 落点也必须与 `stderr.log` 分开：`os.Create` 会截断，指向同一个文件
    /// 就是每次启动都把扩展自己的诊断日志清空。
    private func redirectGoCrashOutput(base: URL) {
        var error: NSError?
        let path = PendingNetTunnelPaths.crashLogURL(in: base).path
        if !LibboxRedirectStderr(path, &error) {
            writeMessage(
                "(packet-tunnel) 接管 Go 崩溃栈输出失败：\(error?.localizedDescription ?? "未知原因")"
            )
        }
    }

    /// 把 `startTunnel` 的失败原文留在 App Group 里，供主 App 展示。
    private func recordStartFailure(_ error: Error, base: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(error.localizedDescription)\n"
        writeMessage("(packet-tunnel) 启动失败：\(error.localizedDescription)")
        do {
            try Data(text.utf8).write(
                to: PendingNetTunnelPaths.lastErrorURL(in: base),
                options: .atomic
            )
        } catch {
            Self.logger.error(
                "写入 last-error.txt 失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 启动成功就把上一次的失败记录抹掉，免得 App 一直展示一条早已过期的
    /// 错误、把用户引到错误的方向上。
    private func clearStartFailure(base: URL) {
        try? FileManager.default.removeItem(at: PendingNetTunnelPaths.lastErrorURL(in: base))
    }

    private func startService() async throws {
        guard let commandServer else {
            throw PendingNetTunnelError.message("command server 尚未启动")
        }
        guard let configContent, !configContent.isEmpty else {
            throw PendingNetTunnelError.message("没有可用配置")
        }
        do {
            try commandServer.startOrReloadService(configContent, options: LibboxOverrideOptions())
        } catch {
            throw PendingNetTunnelError.message("启动服务失败：\(error.localizedDescription)")
        }
    }

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) 停止服务失败：\(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        writeMessage("(packet-tunnel) 重载服务")
        reasserting = true
        defer { reasserting = false }
        try await startService()
    }

    func writeMessage(_ message: String) {
        // 两条互不替代的出口：
        // - `commandServer.writeMessage` 进内核环形缓冲，随 `LibboxCommandLog`
        //   推给订阅中的 command client（只有隧道活着、App 在前台时才有人收）；
        // - fd 2 落到 App Group 的 stderr.log，隧道挂了之后也还读得到。
        // 这里**没有** sing-box 自己的日志——那只在第一条通道里。
        commandServer?.writeMessage(2, message: message)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) 停止，原因：\(reason.rawValue)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    /// 主 App 推来的新配置。与 startTunnel 同样的次序：先让内核接受，
    /// 再落盘 —— 否则一份被拒的配置会留在快照里，毒化下一次 on-demand 自启。
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let content = String(data: messageData, encoding: .utf8), !content.isEmpty else {
            return "空配置".data(using: .utf8)
        }
        guard let base = PendingNetTunnelPaths.container() else {
            return PendingNetTunnelError.message("无法访问 App Group 容器")
                .localizedDescription.data(using: .utf8)
        }
        let previous = configContent
        do {
            configContent = content
            try await reloadService()
        } catch {
            // 回滚：被拒的配置既不该留在内存里（libbox 随时可能回调
            // serviceReload），更不该留在快照里。
            configContent = previous
            return error.localizedDescription.data(using: .utf8)
        }
        persistSnapshot(content, base: base)
        return nil
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}
