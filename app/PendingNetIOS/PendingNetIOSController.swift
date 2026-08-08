import Combine
import Foundation
import SBTallyCore
import UIKit

/// 已配对 VPS 的形状和存储都在 SBTallyCore 里，和 macOS 共用同一份
/// （见 `PairedVPSStore`）—— 两端各存各的、字段还对不齐的时代已经过去了。
typealias IOSPairedServer = PairedVPSRecord

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
    /// iOS 自己的老存档：v1 存的是单台，v2 起存数组。两份都只读一次，搬进
    /// 共用存储之后就不再写了；**不删**——万一用户装回旧版，配对不至于凭空消失。
    private let legacyKey = "pendingnet.ios.paired-server.v1"
    private let legacyServersKey = "pendingnet.ios.paired-servers.v2"
    /// 选中哪一台是「这台设备现在用哪台」，属于本机状态，不跟着 iCloud 走。
    private let selectedKey = "pendingnet.ios.selected-server.v2"
    private let store: PairedVPSStore
    private var cancellables = Set<AnyCancellable>()

    init(store: PairedVPSStore? = nil) {
        let store = store ?? PairedVPSStore()
        self.store = store
        // 同一个 store 交给两边：隧道控制器在 `start` 时用它决定白名单 /
        // 黑名单能不能跑，界面在切换分流模式时用它下载规则集。两份实例会让
        // `isReady` 各说各话。
        let ruleSets = PendingNetRuleSetStore()
        ruleSetStore = ruleSets
        tunnel = PendingNetTunnelController(ruleSetStore: ruleSets)
        loadPersistedServers()
        // 共用存储是真源：本机改动、iCloud 推过来的改动，都从这一条流回界面。
        store.$servers
            .sink { [weak self] in self?.applyStoreServers($0) }
            .store(in: &cancellables)
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

    /// 把 iOS 自己的老存档搬进共用存储（v2 数组优先，没有就看 v1 的单台），
    /// 再接上共用存储当前的名单。
    private func loadPersistedServers() {
        store.adoptLegacy(legacyRecords())
        applyStoreServers(store.servers)
    }

    private func legacyRecords() -> [IOSPairedServer] {
        if let data = defaults.data(forKey: legacyServersKey),
           let decoded = try? JSONDecoder().decode([IOSPairedServer].self, from: data) {
            return decoded
        }
        if let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode(IOSPairedServer.self, from: data) {
            return [legacy]
        }
        return []
    }

    private func applyStoreServers(_ next: [IOSPairedServer]) {
        servers = next
        let remembered = selectedServerID ?? defaults.string(forKey: selectedKey)
        // 记住的那台可能已经不在名单里（存档被改过），退回第一台，别让界面
        // 停在「有服务器但一台都没选中」——那样连接按钮永远是灰的。
        selectedServerID = servers.contains { $0.serverID == remembered }
            ? remembered
            : servers.first?.serverID
        defaults.set(selectedServerID, forKey: selectedKey)
    }

    /// App 启动 / 回到前台时叫一次，把 iCloud 那边的改动拉过来。
    /// iCloud 不可用时是空操作。
    func refreshFromCloud() {
        store.refreshFromCloud()
    }

    private func persistServers() {
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
            store.upsert(paired)
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
            var updated = server
            updated.nodeProtocols = profile.protocols.map(\.displayName)
            if updated != server {
                store.upsert(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
