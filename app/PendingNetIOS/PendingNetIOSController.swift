import Combine
import Foundation
import SBTallyCore
import UIKit

struct IOSPairedServer: Codable, Equatable, Identifiable {
    var id: String { serverID }
    var serverID: String
    var name: String
    var endpoint: String
    var certificateSHA256: String
    var deviceID: String
    var capabilities: [String]
    /// 节点资料拉到之后填上，供「详情」展示。可选，老版本存档里没有这一项。
    var nodeProtocols: [String]?

    /// 列表行上代表这台 VPS 的就是它的 IP（或主机名）—— 不带协议、不带端口，
    /// 与 macOS 的 `PairedVPSServer.address` 同一套规则。
    var address: String {
        if let host = URL(string: endpoint)?.host, !host.isEmpty { return host }
        var text = endpoint
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let colon = text.lastIndex(of: ":") { text = String(text[text.startIndex..<colon]) }
        return text
    }

    /// 控制服务端口，只在「详情」里出现。
    var controlPort: String? {
        if let port = URL(string: endpoint)?.port { return String(port) }
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let tail = String(endpoint[endpoint.index(after: colon)...])
        return Int(tail) == nil ? nil : tail
    }
}

@MainActor
final class PendingNetIOSController: ObservableObject {
    @Published private(set) var servers: [IOSPairedServer] = []
    @Published private(set) var selectedServerID: String?
    @Published private(set) var nodeProfile: PendingNetNodeProfile?
    @Published private(set) var working = false
    /// 正在切换到哪一台（列表行上转圈用）。
    @Published private(set) var switchingServerID: String?
    @Published var message: String?
    @Published var errorMessage: String?

    /// 当前选中的那台。界面与隧道启动都只认它。
    var server: IOSPairedServer? {
        servers.first { $0.serverID == selectedServerID }
    }

    let tunnel: PendingNetTunnelController
    let ruleSetStore: PendingNetRuleSetStore

    private let defaults = UserDefaults.standard
    /// v1 存的是单台（`IOSPairedServer`），v2 起存数组 + 选中项。
    private let legacyKey = "pendingnet.ios.paired-server.v1"
    private let serversKey = "pendingnet.ios.paired-servers.v2"
    private let selectedKey = "pendingnet.ios.selected-server.v2"
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 同一个 store 交给两边：隧道控制器在 `start` 时用它决定 `.bypassCN`
        // 能不能跑，界面在切换分流模式时用它下载规则集。两份实例会让
        // `isReady` 各说各话。
        let store = PendingNetRuleSetStore()
        ruleSetStore = store
        tunnel = PendingNetTunnelController(ruleSetStore: store)
        loadPersistedServers()
        // `tunnel` / `ruleSetStore` 都是独立的 ObservableObject，它们自己的
        // @Published 变化不会自动冒泡到这里——SwiftUI 视图只订阅了
        // `controller` 的 objectWillChange。转发一下，否则隧道状态变化
        // （比如系统层面的连接/断开通知）或规则集下载完成不会触发 UI
        // 刷新，除非 controller 自己的某个 @Published 恰好同时变了。
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ruleSetStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// v2 数组优先；没有就把 v1 的单台迁移过来。迁移**不删** v1 的键——万一
    /// 用户装回旧版，配对不至于凭空消失（Keychain 里的令牌本来就还在）。
    private func loadPersistedServers() {
        if let data = defaults.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([IOSPairedServer].self, from: data) {
            servers = decoded
        } else if let data = defaults.data(forKey: legacyKey),
                  let legacy = try? JSONDecoder().decode(IOSPairedServer.self, from: data) {
            servers = [legacy]
            persistServers()
        }
        let remembered = defaults.string(forKey: selectedKey)
        // 记住的那台可能已经不在名单里（存档被改过），退回第一台，别让界面
        // 停在「有服务器但一台都没选中」——那样连接按钮永远是灰的。
        selectedServerID = servers.contains { $0.serverID == remembered }
            ? remembered
            : servers.first?.serverID
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: serversKey)
        }
        defaults.set(selectedServerID, forKey: selectedKey)
    }

    func importAndEnroll(url: URL) async {
        working = true
        message = nil
        errorMessage = nil
        defer { working = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pairing = try PendingNetPairingFile.decode(Data(contentsOf: url))
            let result = try await PendingNetEnrollmentClient().enroll(
                pairing: pairing,
                deviceName: UIDevice.current.name
            )
            try PendingNetCredentialStore.save(
                accessToken: result.accessToken,
                serverID: result.server.serverID
            )
            let paired = IOSPairedServer(
                serverID: result.server.serverID,
                name: result.server.name,
                endpoint: pairing.control.endpoint,
                certificateSHA256: pairing.control.certificateSHA256,
                deviceID: result.deviceID,
                capabilities: result.server.capabilities,
                // 重新配对同一台时保留上一次拉到的协议名单，免得「详情」在
                // 下一次 refreshNodeProfile 回来之前空一格。
                nodeProtocols: servers.first { $0.serverID == result.server.serverID }?.nodeProtocols
            )
            // 同一台重新配对就地替换，不追加出一行重复的。
            if let index = servers.firstIndex(where: { $0.serverID == paired.serverID }) {
                servers[index] = paired
            } else {
                servers.append(paired)
            }
            selectedServerID = paired.serverID
            persistServers()
            message = "已配对：\(paired.name)"
            await refreshNodeProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 切换到另一台 VPS。
    ///
    /// 隧道**在位**时不能只改选中项就算完：扩展里跑的还是上一台的配置，界面
    /// 却已经打勾在新的那台上——必须把新配置推过去，推失败就把选中项退回原样，
    /// 不能留下「界面指着 A、隧道实际在 B」的状态。
    func select(_ target: IOSPairedServer) async {
        guard target.serverID != selectedServerID else { return }
        let previousID = selectedServerID
        let previousProfile = nodeProfile
        switchingServerID = target.serverID
        defer { switchingServerID = nil }
        message = nil
        errorMessage = nil

        selectedServerID = target.serverID
        await refreshNodeProfile()
        guard let profile = nodeProfile, profile.serverID == target.serverID else {
            // refreshNodeProfile 已经把原因写进 errorMessage 了。
            selectedServerID = previousID
            nodeProfile = previousProfile
            return
        }

        guard tunnel.isTunnelLive else {
            // 未连接：把启动快照也换成新的这台，否则从「设置 → VPN」直接开
            // 隧道会连到上一台去。
            tunnel.setRouteMode(tunnel.routeMode, profile: profile, serverName: target.name)
            persistServers()
            return
        }

        do {
            try await tunnel.reload(profile: profile, serverName: target.name)
            // 选择器 tag 跟着 serverID 走，reload 成功之后才改——控制通道要
            // 订阅的是扩展里**已经生效**的那个分组。
            tunnel.bindSelector(profile: profile, serverName: target.name)
            persistServers()
            message = "已切换到：\(target.name)"
        } catch {
            selectedServerID = previousID
            nodeProfile = previousProfile
            errorMessage = "切换 VPS 失败，已保持原来那台：\(error.localizedDescription)"
        }
    }

    func refreshNodeProfile() async {
        guard let server else { return }
        do {
            guard let token = try PendingNetCredentialStore.load(serverID: server.serverID) else {
                throw PendingNetPairingError.serverRejected("此设备没有找到 VPS 访问凭据，请重新配对")
            }
            let profile = try await PendingNetServerClient(
                endpoint: server.endpoint,
                certificateSHA256: server.certificateSHA256,
                accessToken: token
            ).nodeProfile()
            guard profile.serverID == server.serverID else {
                throw PendingNetPairingError.invalidServerResponse
            }
            nodeProfile = profile
            // 协议名单落进存档，「详情」在没网的时候也有东西可显示。
            if let index = servers.firstIndex(where: { $0.serverID == server.serverID }) {
                servers[index].nodeProtocols = profile.protocols.map(\.displayName)
                persistServers()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
