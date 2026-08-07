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
        subsystem: "net.pending.PendingNet.ios.PacketTunnel",
        category: "Provider"
    )

    private lazy var platformInterface = PendingNetPlatformInterface(self)
    private(set) var commandServer: LibboxCommandServer?
    private var configContent: String?

    override func startTunnel(options startOptions: [String: NSObject]?) async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetTunnelError.message("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        // 先于一切：sing-box 的 log 走 stderr，不重定向就没有任何日志出口。
        redirectStderr(base: base)

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

    private func redirectStderr(base: URL) {
        var error: NSError?
        let path = PendingNetTunnelPaths.stderrLogURL(in: base).path
        if !LibboxRedirectStderr(path, &error) {
            // 只能走 os.Logger —— 此刻 stderr 和 command server 都还没有。
            Self.logger.error(
                "重定向 stderr 到 \(path, privacy: .public) 失败：\(error?.localizedDescription ?? "未知原因", privacy: .public)"
            )
        }
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
        commandServer?.writeMessage(2, message: message)
        // stderr 已重定向到 App Group 里的 stderr.log，扩展自己的诊断信息
        // 和 sing-box 的日志就落在同一个文件、同一条时间线上。
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
