import Combine
import Foundation
import SBTallyCore

private enum VPSPairingControllerError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .missingCredential: "找不到这台 VPS 的设备凭据，请重新导入 .pdn 文件"
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
    @Published var lastError: String?
    @Published var lastMessage: String?

    private let store: PairedVPSStore
    private var cancellables = Set<AnyCancellable>()

    /// `legacyServers` 是从旧 bundle id 那个 `UserDefaults` 域里搬出来的存档
    /// （见 `PendingNetLegacyDefaultsMigration`）。走 `adoptLegacy` 而不是直接写
    /// key：那批记录得和 iCloud 那边按 `updatedAt` 合并，而且老记录不该盖新时间戳。
    init(store: PairedVPSStore? = nil, legacyServers: [PairedVPSRecord] = []) {
        let store = store ?? PairedVPSStore()
        self.store = store
        store.adoptLegacy(legacyServers)
        servers = store.servers
        // 存储层是真源：本机改动、iCloud 推过来的改动，都从这一条流回界面。
        store.$servers
            .sink { [weak self] in self?.servers = $0 }
            .store(in: &cancellables)
    }

    /// App 启动 / 回到前台时叫一次，把 iCloud 那边的改动拉过来。
    /// iCloud 不可用时是空操作。
    func refreshFromCloud() {
        store.refreshFromCloud()
    }

    func importAndEnroll(url: URL) async -> PendingNetRuntimeServer? {
        pairing = true
        lastError = nil
        lastMessage = nil
        defer { pairing = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try PendingNetPairingFile.decode(Data(contentsOf: url))
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
            upsert(record)
            return try nodeProfile.runtimeServer(name: record.name)
        } catch {
            // Clear the success line too — otherwise the GUI shows a green
            // 「已应用并连接」 next to the red failure.
            lastMessage = nil
            lastError = detailedMessage(for: error)
            return nil
        }
    }

    func runtimeServer(for record: PairedVPSServer) async -> PendingNetRuntimeServer? {
        pairing = true
        lastError = nil
        defer { pairing = false }
        do {
            guard let accessToken = try PendingNetCredentialStore.load(serverID: record.serverID) else {
                throw VPSPairingControllerError.missingCredential
            }
            let nodeProfile = try await PendingNetServerClient(
                endpoint: record.endpoint,
                certificateSHA256: record.certificateSHA256,
                accessToken: accessToken
            ).nodeProfile()
            var updated = record
            updated.nodeProtocols = nodeProfile.protocols.map(\.type)
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
