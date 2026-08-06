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

struct PairedVPSServer: Codable, Identifiable, Equatable {
    var id: String { serverID }
    var serverID: String
    var name: String
    var endpoint: String
    var certificateSHA256: String
    var deviceID: String
    var capabilities: [String]
    var nodeProtocols: [String]?
    var pairedAt: Date
}

@MainActor
final class VPSPairingController: ObservableObject {
    @Published private(set) var servers: [PairedVPSServer] = []
    @Published private(set) var pairing = false
    @Published var lastError: String?
    @Published var lastMessage: String?

    private let defaults: UserDefaults
    private let defaultsKey = "pendingnet.paired-vps.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
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
            lastMessage = "已配对，正在准备本机配置：\(record.name)"
            return try nodeProfile.runtimeServer(name: record.name)
        } catch {
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
            lastError = detailedMessage(for: error)
            return nil
        }
    }

    func markApplied(_ runtime: PendingNetRuntimeServer) {
        lastError = nil
        lastMessage = "已应用并连接：\(runtime.name)"
    }

    func reportApplyError(_ message: String) {
        lastError = message
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PairedVPSServer].self, from: data) else {
            servers = []
            return
        }
        servers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func upsert(_ record: PairedVPSServer) {
        if let index = servers.firstIndex(where: { $0.serverID == record.serverID }) {
            servers[index] = record
        } else {
            servers.append(record)
        }
        servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    private func detailedMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription)（URL 错误 \(urlError.errorCode)）"
        }
        return error.localizedDescription
    }
}
