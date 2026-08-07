import Foundation
@preconcurrency import NetworkExtension
import SBTallyCore

/// 驱动 Packet Tunnel Extension 的 App 侧控制器：安装/查找
/// `NETunnelProviderManager`、启停隧道、在隧道运行中热切换分流模式。
///
/// 配置内容随 `startTunnel` 的 options 下发给扩展，不写进
/// `providerConfiguration`——VPN profile 保存在系统 preferences
/// 数据库里，不具备 App Group 文件同等的数据保护属性，因此任何密钥或
/// 连接材料都不允许进入 `providerConfiguration`。扩展自己会在 libbox
/// 接受配置之后才把这份配置落盘为快照（见 `PacketTunnelProvider`），
/// 这个次序是故意的：本控制器不做重复的落盘，避免绕开这个保护。
@MainActor
final class PendingNetTunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published var routeMode: PendingNetRouteMode = .global

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private let tunnelBundleID = "net.pending.PendingNet.ios.PacketTunnel"
    private let routeModeKey = "pendingnet.ios.route-mode.v1"

    init() {
        if let raw = UserDefaults.standard.string(forKey: routeModeKey),
           let mode = PendingNetRouteMode(rawValue: raw) {
            routeMode = mode
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 查找系统里已安装的 PendingNet 隧道 profile（如果有）并订阅其状态。
    /// 找不到也不是错误——用户可能还没连过一次，`start` 会负责安装。
    func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let existing = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelBundleID
        }
        manager = existing
        status = existing?.connection.status ?? .invalid
        observeStatus()
    }

    /// 每次 manager 被替换（新装、reload 后 loadFromPreferences 换了实例）
    /// 都要先摘掉旧观察者再挂新的，否则要么漏订阅新状态，要么残留一个
    /// 指向旧 connection 的观察者。
    private func observeStatus() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = connection.status }
        }
    }

    func setRouteMode(_ mode: PendingNetRouteMode) {
        routeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: routeModeKey)
    }

    /// 生成配置并启动隧道。
    ///
    /// 启动前先确认 Keychain 里有设备令牌：没有令牌意味着配对已失效，
    /// 此时隧道即使起得来也拿不到后续的节点资料刷新，应当直接拦住并
    /// 要求重新配对，而不是让用户面对一条不会自愈的连接。
    func start(
        profile: PendingNetNodeProfile,
        serverName: String,
        serverID: String
    ) async throws {
        guard try PendingNetCredentialStore.load(serverID: serverID) != nil else {
            throw PendingNetPairingError.serverRejected("此设备没有找到 VPS 访问凭据，请重新配对")
        }
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        let manager = try await installedManager()
        try manager.connection.startVPNTunnel(options: [
            "configContent": content as NSString,
        ])
    }

    func stop() async {
        manager?.connection.stopVPNTunnel()
    }

    /// Task 10 切换分流模式时调用：隧道已连接才有意义，未连接直接跳过——
    /// 新的分流模式会在下一次 `start` 里随配置一起生效。
    func reload(profile: PendingNetNodeProfile, serverName: String) async throws {
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        try session.sendProviderMessage(Data(content.utf8)) { response in
            if let response, let text = String(data: response, encoding: .utf8), !text.isEmpty {
                NSLog("[PendingNet] reload failed: %@", text)
            }
        }
    }

    private func makeConfigContent(
        profile: PendingNetNodeProfile,
        serverName: String
    ) throws -> String {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: try profile.runtimeServer(name: serverName),
            routeMode: routeMode,
            ruleSetDirectory: PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            cachePath: PendingNetTunnelPaths.cacheURL(in: base).path
        )
        // 仅用于真机排查「App 生成的配置到底长什么样」的调试留痕，
        // 不是配置传递给扩展的机制——扩展永远只认 startTunnel 的
        // options（或它自己落的快照），不读这个文件。就算这次写入
        // 失败也不影响隧道启动，因此这里不检查返回值、不抛错。
        try? data.write(to: PendingNetTunnelPaths.configURL(in: base), options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }

    private func installedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "PendingNet"
        // 只放版本号，任何密钥或连接材料都不进 VPN profile。这个字段本身
        // 也不参与任何比对逻辑——配置更新走 options 下发 + sendProviderMessage
        // 主动 reload，版本号纯粹是占位。
        proto.providerConfiguration = ["configVersion": 1]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "PendingNet"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observeStatus()
        return manager
    }
}
