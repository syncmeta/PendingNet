import Foundation
import Libbox
import NetworkExtension
import SBTallyCore

/// PendingNet 的 Packet Tunnel Extension：把 sing-box libbox 内核跑起来。
///
/// 扩展**不联网**：不刷新 `/v1/node`、不下载规则集、没有 HTTP 客户端。
/// 它只读 App Group 里由主 App 写好的本地文件，路径一律取自
/// `PendingNetTunnelPaths`。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var platformInterface = PendingNetPlatformInterface(self)
    private(set) var commandServer: LibboxCommandServer?
    private var configContent: String?

    override func startTunnel(options startOptions: [String: NSObject]?) async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetTunnelError.message("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)

        configContent = try resolveConfigContent(options: startOptions, base: base)

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
        writeMessage("(packet-tunnel) PendingNet 隧道已就绪")
    }

    /// 配置来源两级：优先 startTunnel options，回退持久化快照。
    ///
    /// 系统按 on-demand 规则在 App 未运行时拉起隧道时 options 为空，
    /// 只认 options 会导致自启永远失败；只读文件则拿不到本次启动的新配置。
    /// 因此拿到 options 里的配置后必须**立即**落盘。
    private func resolveConfigContent(options: [String: NSObject]?, base: URL) throws -> String {
        let snapshot = PendingNetTunnelPaths.snapshotURL(in: base)
        if let content = options?["configContent"] as? String, !content.isEmpty {
            do {
                try Data(content.utf8).write(to: snapshot, options: .atomic)
            } catch {
                throw PendingNetTunnelError.message(
                    "写入配置快照失败：\(error.localizedDescription)"
                )
            }
            return content
        }
        guard let data = try? Data(contentsOf: snapshot),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty
        else {
            throw PendingNetTunnelError.message("没有可用配置，请回到 PendingNet 完成配对")
        }
        return content
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

    /// 主 App 推来的新配置。与 startTunnel 一样两级落盘，
    /// 否则下一次 on-demand 自启会退回旧配置。
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let content = String(data: messageData, encoding: .utf8), !content.isEmpty else {
            return "空配置".data(using: .utf8)
        }
        do {
            guard let base = PendingNetTunnelPaths.container() else {
                throw PendingNetTunnelError.message("无法访问 App Group 容器")
            }
            try Data(content.utf8).write(
                to: PendingNetTunnelPaths.snapshotURL(in: base),
                options: .atomic
            )
            configContent = content
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}
