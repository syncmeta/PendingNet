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
    /// iCloud 把 VPS 记录同步过来了、但这台设备上没有对应访问凭据的那几台。
    /// 列表靠它把行标成「未配对」——记录走 iCloud 键值存储、凭据走 iCloud
    /// 钥匙串，两条链各走各的，只到了一半是常态。
    @Published private(set) var unpairedServerIDs: Set<String> = []
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
        refreshCredentialState()
        let remembered = selectedServerID ?? defaults.string(forKey: selectedKey)
        // 记住的那台可能已经不在名单里（存档被改过），退回第一台，别让界面
        // 停在「有服务器但一台都没选中」——那样连接按钮永远是灰的。
        // 本机没凭据的那几台跳过：选中它等于让连接按钮指着一台注定失败的 VPS。
        let usable = servers.filter { !unpairedServerIDs.contains($0.serverID) }
        selectedServerID = usable.contains { $0.serverID == remembered }
            ? remembered
            : usable.first?.serverID
        defaults.set(selectedServerID, forKey: selectedKey)
    }

    /// 把还躺在老位置上的令牌搬到能经 iCloud 同步的位置，顺带记下这台设备
    /// 缺哪几台的凭据。
    ///
    /// 搬迁本来只搭在读令牌那条路上，而读只发生在用户点某台 VPS 的时候；
    /// 主动跑一遍，同步才不用等用户先做点什么。
    private func refreshCredentialState() {
        let outcomes = PendingNetCredentialStore.promoteAll(serverIDs: servers.map(\.serverID))
        // 只把「确实没有」标成未配对。钥匙串读不了时说不准，标了就是把用户支去
        // 做一次白费的重新配对。
        unpairedServerIDs = Set(outcomes.filter { $0.value == .notStored }.keys)
    }

    /// App 启动 / 回到前台时叫一次，把 iCloud 那边的改动拉过来。
    /// iCloud 不可用时是空操作。
    func refreshFromCloud() {
        store.refreshFromCloud()
        // iCloud 钥匙串可能比键值存储晚到：记录先到、凭据后到时，回到前台
        // 这一下就是那几行从「未配对」转正的时机。
        refreshCredentialState()
    }

    private func persistServers() {
        defaults.set(selectedServerID, forKey: selectedKey)
    }

    /// 唯一的导入入口：一行一个 PendingNet 配对链接或通用节点分享链接。
    func importAndEnroll(pasted text: String) async {
        working = true
        message = nil
        errorMessage = nil
        defer { working = false }

        do {
            let items = try PendingNetTextImport.decode(text)
            for item in items {
                switch item {
                case .pairing(let pairing):
                    try await enroll(pairing)
                case .sharedNode(let node):
                    try PendingNetCredentialStore.save(
                        accessToken: node.originalLink,
                        serverID: node.record.serverID
                    )
                    store.upsert(node.record)
                    unpairedServerIDs.remove(node.record.serverID)
                    selectedServerID = node.record.serverID
                    nodeProfile = node.profile
                    persistServers()
                }
            }
            message = "已导入 \(items.count) 个节点"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enroll(_ pairing: PendingNetPairingFile) async throws {
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
            nodeProtocols: servers.first { $0.serverID == result.server.serverID }?.nodeProtocols
        )
        store.upsert(paired)
        unpairedServerIDs.remove(paired.serverID)
        selectedServerID = paired.serverID
        persistServers()
        await refreshNodeProfile()
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
        } catch {
            selectedServerID = previousID
            nodeProfile = previousProfile
            errorMessage = "切换 VPS 失败，已保持原来那台：\(error.localizedDescription)"
        }
    }

    /// 改端口 / 允许局域网访问。返回 nil 表示成功，否则是给用户看的人话。
    /// 形状与 macOS 的 `EngineController.setLocalInbound` 一样，设置页那张卡
    /// 两端共用一个。
    func setLocalInbound(port: Int, allowLAN: Bool) async -> String? {
        // 隧道在跑却没有节点资料的话就改不成（要重新生成整份配置推给扩展）。
        // 先补一次，补不到由 tunnel 那边如实报错，不假装存上了。
        if nodeProfile == nil, server != nil { await refreshNodeProfile() }
        do {
            try await tunnel.setLocalInbound(
                PendingNetLocalInbound(port: port, allowsLAN: allowLAN),
                profile: nodeProfile,
                serverName: server?.name
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshNodeProfile() async {
        guard let server else { return }
        do {
            guard let token = try PendingNetCredentialStore.load(serverID: server.serverID) else {
                throw PendingNetPairingError.serverRejected("这台设备还没有这台 VPS 的访问凭据，请重新导入它的链接")
            }
            if server.isSharedNode {
                nodeProfile = try PendingNetSharedNode.decode(link: token).profile
                return
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
            // 代理入口的 TCP 端口跟着记录一起存，延迟才知道该测哪里。
            updated.adoptProxyEntry(from: profile)
            if updated != server {
                store.upsert(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
