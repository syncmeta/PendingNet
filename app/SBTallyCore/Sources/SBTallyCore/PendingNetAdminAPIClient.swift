import Foundation

public enum PendingNetAdminAPIError: LocalizedError, Equatable {
    case missingCredential
    case rejected(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingCredential: pendingNetAdminLocalized("这台设备没有管理凭据，请在“管理”页面重新导入管理链接")
        case .rejected(let statusCode):
            String(format: pendingNetAdminLocalized("管理请求被服务器拒绝（HTTP %ld）"), statusCode)
        case .invalidResponse: pendingNetAdminLocalized("服务器返回了无效的管理数据")
        }
    }
}

public struct PendingNetAdminUser: Decodable, Equatable, Sendable, Identifiable {
    public struct Traffic: Decodable, Equatable, Sendable { public let upload: Int64; public let download: Int64 }
    public let traffic: Traffic?
    public struct LoginIP: Decodable, Equatable, Sendable {
        public let ip: String
        public let firstSeenAt: String

        enum CodingKeys: String, CodingKey {
            case ip
            case firstSeenAt = "first_seen_at"
        }
    }

    public let id: String
    public let name: String
    public let role: String?
    public let createdAt: String
    public let revokedAt: String?
    public let loginIPs: [LoginIP]?

    enum CodingKeys: String, CodingKey {
        case id, name, role, traffic
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case loginIPs = "login_ips"
    }
}

/// The raw documents may contain proxy credentials. Keep them transient and
/// outside the ordinary VPS record, UserDefaults and diagnostics.
public struct PendingNetAdminConfigSnapshot: Equatable, Sendable {
    public let revision: String
    public let node: Data
    public let xray: Data
    public let hysteria: Data
}

public enum PendingNetAdminPairingRole: String, Sendable {
    case client
    case admin
}

public enum PendingNetClientConfigPlatform: String, Sendable {
    case android
    case windows
}

/// Keep the grant only in the caller's memory; never put it in server metadata.
public struct PendingNetIssuedPairing: Sendable {
    public let link: String
    public let expiresAt: Date
}

/// Production requests use the same pinned TLS
/// transport as pairing; URLSession is injected only by module tests.
public struct PendingNetAdminAPIClient: Sendable {
    private let server: PendingNetManagedServer
    private let credentialStore: PendingNetCredentialStoreCore
    private let session: URLSession?

    public init(server: PendingNetManagedServer) {
        self.server = server
        credentialStore = PendingNetAdminCredentialStore.makeCore(backend: SecItemKeychainBackend())
        session = nil
    }

    init(server: PendingNetManagedServer, credentialStore: PendingNetCredentialStoreCore, session: URLSession?) {
        self.server = server
        self.credentialStore = credentialStore
        self.session = session
    }

    public func users() async throws -> [PendingNetAdminUser] {
        let data = try await get(path: "/v1/admin/users")
        guard data.count <= 1 << 20,
              let value = try? JSONDecoder().decode(UsersResponse.self, from: data),
              value.users.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else {
            throw PendingNetAdminAPIError.invalidResponse
        }
        return value.users
    }

    public func nodeProfile(userID: String? = nil) async throws -> PendingNetNodeProfile {
        var path = "/v1/node"
        if let userID {
            guard !userID.isEmpty, userID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw PendingNetAdminAPIError.invalidResponse }
            path = "/v1/admin/users/\(userID)/node"
        }
        let data = try await get(path: path)
        guard data.count <= 1 << 20,
              let profile = try? JSONDecoder().decode(PendingNetNodeProfile.self, from: data),
              profile.serverID == server.serverID else { throw PendingNetAdminAPIError.invalidResponse }
        _ = try profile.runtimeServer(name: server.name)
        return profile
    }

    public func renameUser(id: String, name: String) async throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw PendingNetAdminAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let data = try await request(path: "/v1/admin/users/\(id)/rename", method: "POST", body: body, expectedStatus: 204)
        guard data.isEmpty else { throw PendingNetAdminAPIError.invalidResponse }
    }

    public func config() async throws -> PendingNetAdminConfigSnapshot {
        let data = try await get(path: "/v1/admin/config")
        guard data.count <= 3 * (1 << 20) + 4096,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["revision", "node", "xray", "hysteria"],
              let revision = root["revision"] as? String,
              revision.count == 64, revision.allSatisfy({ $0.isHexDigit }),
              let node = root["node"] as? [String: Any],
              let xray = root["xray"] as? [String: Any],
              let hysteria = root["hysteria"] as? [String: Any],
              let nodeData = try? JSONSerialization.data(withJSONObject: node),
              let xrayData = try? JSONSerialization.data(withJSONObject: xray),
              let hysteriaData = try? JSONSerialization.data(withJSONObject: hysteria) else {
            throw PendingNetAdminAPIError.invalidResponse
        }
        return PendingNetAdminConfigSnapshot(
            revision: revision, node: nodeData, xray: xrayData, hysteria: hysteriaData
        )
    }

    public func revokeUser(id: String) async throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { throw PendingNetAdminAPIError.invalidResponse }
        let data = try await request(path: "/v1/admin/users/\(id)/revoke", method: "POST", expectedStatus: 204)
        guard data.isEmpty else { throw PendingNetAdminAPIError.invalidResponse }
    }

    public func issuePairing(role: PendingNetAdminPairingRole, ttlSeconds: Int) async throws -> PendingNetIssuedPairing {
        guard (1...86400).contains(ttlSeconds) else { throw PendingNetAdminAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["role": role.rawValue, "ttl_seconds": ttlSeconds])
        let data = try await request(path: "/v1/admin/pairings", method: "POST", body: body, expectedStatus: 201)
        guard data.count <= 1 << 20,
              let response = try? JSONDecoder().decode(IssuedPairingResponse.self, from: data),
              let pairing = try? PendingNetPairingFile.decode(link: response.link),
              pairing.serverID == server.serverID,
              pairing.control.endpoint == server.endpoint,
              pairing.control.certificateSHA256.caseInsensitiveCompare(server.certificateSHA256) == .orderedSame,
              (role == .admin) == (pairing.enrollment.role == "admin") else {
            throw PendingNetAdminAPIError.invalidResponse
        }
        return PendingNetIssuedPairing(link: response.link, expiresAt: pairing.enrollment.expiresAt)
    }

    /// Returns secret-bearing JSON only to the caller; it is not persisted or
    /// routed through the ordinary connection store.
    public func clientConfig(platform: PendingNetClientConfigPlatform) async throws -> Data {
        let data = try await get(path: "/v1/admin/client-config?platform=\(platform.rawValue)")
        guard data.count <= 1 << 20,
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = config["inbounds"] as? [[String: Any]], !inbounds.isEmpty,
              inbounds.contains(where: { $0["type"] as? String == (platform == .android ? "tun" : "mixed") }),
              let outbounds = config["outbounds"] as? [[String: Any]],
              outbounds.contains(where: {
                  $0["type"] as? String == "vless" &&
                  !($0["uuid"] as? String ?? "").isEmpty
              }),
              config["route"] is [String: Any] else {
            throw PendingNetAdminAPIError.invalidResponse
        }
        return data
    }

    private func get(path: String) async throws -> Data {
        try await request(path: path, method: "GET", expectedStatus: 200)
    }

    private func request(path: String, method: String, body: Data? = nil, expectedStatus: Int) async throws -> Data {
        guard let token = try credentialStore.load(serverID: server.serverID), !token.isEmpty else {
            throw PendingNetAdminAPIError.missingCredential
        }
        let statusCode: Int
        let data: Data
        if let session {
            guard let baseURL = URL(string: server.endpoint) else {
                throw PendingNetPairingError.invalidEndpoint
            }
            guard let requestURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
                throw PendingNetPairingError.invalidEndpoint
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PendingNetAdminAPIError.invalidResponse
            }
            statusCode = http.statusCode
            data = body
        } else {
            let response = try await PendingNetPinnedHTTPClient(
                endpoint: server.endpoint,
                certificateSHA256: server.certificateSHA256
            ).request(path: path, method: method, authorization: "Bearer \(token)", body: body)
            statusCode = response.statusCode
            data = response.body
        }
        guard statusCode == expectedStatus else {
            throw PendingNetAdminAPIError.rejected(statusCode: statusCode)
        }
        return data
    }

    private struct UsersResponse: Decodable {
        let users: [PendingNetAdminUser]
    }

    private struct IssuedPairingResponse: Decodable {
        let link: String
    }
}
