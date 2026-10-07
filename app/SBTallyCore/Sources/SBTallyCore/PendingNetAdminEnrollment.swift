import Foundation

/// Non-secret management endpoint identity. It does not make the server a proxy
/// connection, and must not be saved in PairedVPSStore.
public struct PendingNetManagedServer: Equatable, Sendable, Identifiable, Codable {
    public let serverID: String
    public let name: String
    public let endpoint: String
    public let certificateSHA256: String
    public let deviceID: String

    public var id: String { serverID }
}

public enum PendingNetAdminEnrollmentError: LocalizedError, Equatable {
    case notManagementLink

    public var errorDescription: String? {
        switch self {
        case .notManagementLink:
            pendingNetAdminLocalized("这不是管理链接，请在普通节点的“导入”页面使用")
        }
    }
}

/// Admin links have a separate entry point from PendingNetTextImport. The
/// one-time grant is consumed only after role validation; the issued token is
/// persisted only in the local-only admin Keychain service.
public struct PendingNetAdminEnrollmentClient: Sendable {
    private let session: URLSession?
    private let credentialStore: PendingNetCredentialStoreCore

    public init(session: URLSession? = nil) {
        self.session = session
        credentialStore = PendingNetAdminCredentialStore.makeCore(backend: SecItemKeychainBackend())
    }

    init(session: URLSession?, credentialStore: PendingNetCredentialStoreCore) {
        self.session = session
        self.credentialStore = credentialStore
    }

    public func enroll(
        link: String,
        deviceName: String,
        now: Date = Date()
    ) async throws -> PendingNetManagedServer {
        let pairing = try PendingNetPairingFile.decode(link: link, now: now)
        guard pairing.enrollment.role == "admin" else {
            throw PendingNetAdminEnrollmentError.notManagementLink
        }
        let enrolled = try await PendingNetEnrollmentClient(session: session)
            .enroll(pairing: pairing, deviceName: deviceName, now: now)
        guard enrolled.role == "admin" else {
            throw PendingNetPairingError.invalidServerResponse
        }
        try credentialStore.save(accessToken: enrolled.accessToken, serverID: enrolled.server.serverID)
        return PendingNetManagedServer(
            serverID: enrolled.server.serverID,
            name: enrolled.server.name,
            endpoint: pairing.control.endpoint,
            certificateSHA256: pairing.control.certificateSHA256,
            deviceID: enrolled.deviceID
        )
    }
}
