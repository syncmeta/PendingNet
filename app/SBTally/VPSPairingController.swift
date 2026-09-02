import Combine
import Foundation
import SBTallyCore

private enum VPSPairingControllerError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .missingCredential: "找不到这台 VPS 的设备凭据，请重新导入它的链接"
        }
    }
}

/// 已配对 VPS 的形状和存储都在 SBTallyCore 里，和 iOS 共用同一份
/// （见 `PairedVPSStore`）—— 两端各存各的时代已经过去了。
typealias PairedVPSServer = PairedVPSRecord

@MainActor
final class VPSPairingController: ObservableObject {
    @Published private(set) var servers: [PairedVPSServer] = []
    @Published private(set) var pairing = false
    /// iCloud 把 VPS 记录同步过来了、但这台设备上没有对应访问凭据的那几台。
    /// 列表靠它把行标成「未配对」——记录走 iCloud 键值存储、凭据走 iCloud
    /// 钥匙串，两条链各走各的，只到了一半是常态。
    @Published private(set) var unpairedServerIDs: Set<String> = []
    @Published var lastError: String?
    @Published var lastMessage: String?

    private let store: PairedVPSStore
    private var cancellables = Set<AnyCancellable>()
    private var operationGate = PendingNetConnectionOperationGate()

    /// `legacyServers` 是从旧 bundle id 那个 `UserDefaults` 域里搬出来的存档
    /// （见 `PendingNetLegacyDefaultsMigration`）。走 `adoptLegacy` 而不是直接写
    /// key：那批记录得和 iCloud 那边按 `updatedAt` 合并，而且老记录不该盖新时间戳。
    init(store: PairedVPSStore? = nil, legacyServers: [PairedVPSRecord] = []) {
        let store = store ?? PairedVPSStore()
        self.store = store
        store.adoptLegacy(legacyServers)
        servers = store.servers
        refreshCredentialState()
        // 存储层是真源：本机改动、iCloud 推过来的改动，都从这一条流回界面。
        store.$servers
            .sink { [weak self] in
                self?.servers = $0
                self?.refreshCredentialState()
            }
            .store(in: &cancellables)
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

    /// 唯一的导入入口：一行一个 PendingNet 配对链接或通用节点分享链接。
    func importAndEnroll(pasted text: String) async -> PendingNetRuntimeServer? {
        lastError = nil
        lastMessage = nil

        do {
            let items = try PendingNetTextImport.decode(text)
            var lastRuntime: PendingNetRuntimeServer?
            for item in items {
                switch item {
                case .pairing(let file):
                    lastRuntime = try await enroll(file)
                case .sharedNode(let node):
                    try PendingNetCredentialStore.save(
                        accessToken: node.originalLink,
                        serverID: node.record.serverID
                    )
                    upsert(node.record)
                    unpairedServerIDs.remove(node.record.serverID)
                    lastRuntime = try node.runtimeServer()
                }
            }
            lastMessage = "已导入 \(items.count) 个节点"
            return lastRuntime
        } catch {
            lastMessage = nil
            lastError = detailedMessage(for: error)
            return nil
        }
    }

    private func enroll(_ file: PendingNetPairingFile) async throws -> PendingNetRuntimeServer {
        let result = try await PendingNetEnrollmentClient().enroll(
            pairing: file,
            deviceName: ProcessInfo.processInfo.hostName
        )
        try PendingNetCredentialStore.save(
            accessToken: result.accessToken,
            serverID: result.server.serverID
        )
        var record = PairedVPSServer(
            serverID: result.server.serverID,
            name: result.server.name,
            endpoint: file.control.endpoint,
            certificateSHA256: file.control.certificateSHA256,
            deviceID: result.deviceID,
            capabilities: result.server.capabilities,
            nodeProtocols: nil,
            pairedAt: Date()
        )
        upsert(record)

        let nodeProfile = try await PendingNetServerClient(
            endpoint: file.control.endpoint,
            certificateSHA256: file.control.certificateSHA256,
            accessToken: result.accessToken
        ).nodeProfile()
        record.nodeProtocols = nodeProfile.protocols.map(\.type)
        record.adoptProxyEntry(from: nodeProfile)
        upsert(record)
        return try nodeProfile.runtimeServer(name: record.name)
    }

    func runtimeServer(for record: PairedVPSServer) async -> PendingNetRuntimeServer? {
        lastError = nil
        do {
            guard let accessToken = try PendingNetCredentialStore.load(serverID: record.serverID) else {
                throw VPSPairingControllerError.missingCredential
            }
            if record.isSharedNode {
                return try PendingNetSharedNode.decode(link: accessToken).runtimeServer()
            }
            let nodeProfile = try await PendingNetServerClient(
                endpoint: record.endpoint,
                certificateSHA256: record.certificateSHA256,
                accessToken: accessToken
            ).nodeProfile()
            var updated = record
            updated.nodeProtocols = nodeProfile.protocols.map(\.type)
            updated.adoptProxyEntry(from: nodeProfile)
            upsert(updated)
            return try nodeProfile.runtimeServer(name: record.name)
        } catch {
            // Clear the success line too — otherwise the GUI shows a green
            // 「已应用并连接」 next to the red failure.
            lastMessage = nil
            lastError = detailedMessage(for: error)
            return nil
        }
    }

    /// 切换成功不再留一行「已应用并连接」——点哪台就是切到哪台，选中的那颗
    /// 药丸和顶部状态药丸已经把状态说完了，中间态文案只是噪音。
    func markApplied(_ runtime: PendingNetRuntimeServer) {
        lastError = nil
        lastMessage = nil
    }

    func reportApplyError(_ message: String) {
        lastMessage = nil
        lastError = message
    }

    /// 把“取节点资料 + 写配置 + 重启 + 回读 selector”整段锁成一笔。
    /// 视图层的 disabled 只能拦下一次点击，拦不住已经排进 Task 队列的第二次点击。
    func beginConnectionChange() -> Bool {
        guard operationGate.begin() else { return false }
        pairing = true
        return true
    }

    func endConnectionChange() {
        operationGate.end()
        pairing = false
    }

    private func upsert(_ record: PairedVPSServer) {
        store.upsert(record)
    }

    private func detailedMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription)（URL 错误 \(urlError.errorCode)）"
        }
        return error.localizedDescription
    }
}
