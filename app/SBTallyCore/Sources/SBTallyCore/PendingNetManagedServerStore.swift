import Foundation

public enum PendingNetManagedServerStoreError: LocalizedError {
    case unreadable
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: pendingNetAdminLocalized("本机管理服务器列表无法读取，尚未覆盖原有数据")
        case .writeFailed: pendingNetAdminLocalized("本机管理服务器列表保存失败")
        }
    }
}

/// Local-only, non-secret metadata for management entry points. Admin tokens
/// remain in PendingNetAdminCredentialStore; no value is sent to iCloud KVS or
/// the ordinary PairedVPSStore used by proxy connections.
public final class PendingNetManagedServerStore {
    public static let defaultLocalKey = "pendingnet.managed-servers.v1"

    public private(set) var servers: [PendingNetManagedServer]
    private let defaults: UserDefaults
    private let key: String
    private let unreadable: Bool

    public init(defaults: UserDefaults = .standard, key: String = defaultLocalKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            if let decoded = try? JSONDecoder().decode([PendingNetManagedServer].self, from: data),
               decoded.allSatisfy({ !$0.serverID.isEmpty }),
               Set(decoded.map(\.serverID)).count == decoded.count {
                servers = decoded
                unreadable = false
            } else {
                servers = []
                unreadable = true
            }
        } else {
            servers = []
            unreadable = false
        }
    }

    public func upsert(_ server: PendingNetManagedServer) throws {
        guard !unreadable else { throw PendingNetManagedServerStoreError.unreadable }
        var next = servers.filter { $0.serverID != server.serverID }
        next.append(server)
        next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw PendingNetManagedServerStoreError.writeFailed
        }
        servers = next
    }

    /// Verify local metadata can be durably written before consuming a
    /// one-time admin grant. This does not involve Keychain or iCloud.
    public func ensureWritable() throws {
        guard !unreadable else { throw PendingNetManagedServerStoreError.unreadable }
        let data = try JSONEncoder().encode(servers)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw PendingNetManagedServerStoreError.writeFailed
        }
    }
}
