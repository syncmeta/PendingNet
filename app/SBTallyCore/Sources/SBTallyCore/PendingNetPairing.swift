import CryptoKit
import Foundation
import Security

public struct PendingNetPairingFile: Codable, Equatable, Sendable {
    public static let currentFormat = "pendingnet-pairing"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var serverID: String
    public var name: String
    public var control: Control
    public var enrollment: Enrollment

    public struct Control: Codable, Equatable, Sendable {
        public var endpoint: String
        public var certificateSHA256: String

        enum CodingKeys: String, CodingKey {
            case endpoint
            case certificateSHA256 = "certificate_sha256"
        }
    }

    public struct Enrollment: Codable, Equatable, Sendable {
        public var token: String
        public var expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case format, version, name, control, enrollment
        case serverID = "server_id"
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        try validateDocumentKeys(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        try value.validate(now: now)
        return value
    }

    private static func validateDocumentKeys(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["format", "version", "server_id", "name", "control", "enrollment"],
              let control = root["control"] as? [String: Any],
              Set(control.keys) == ["endpoint", "certificate_sha256"],
              let enrollment = root["enrollment"] as? [String: Any],
              Set(enrollment.keys) == ["token", "expires_at"] else {
            throw PendingNetPairingError.unexpectedFields
        }
    }

    public func validate(now: Date = Date()) throws {
        guard format == Self.currentFormat else {
            throw PendingNetPairingError.unsupportedFormat(format)
        }
        guard version == Self.currentVersion else {
            throw PendingNetPairingError.unsupportedVersion(version)
        }
        guard !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PendingNetPairingError.missingIdentity
        }
        guard let components = URLComponents(string: control.endpoint),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw PendingNetPairingError.invalidEndpoint
        }
        let fingerprint = control.certificateSHA256.lowercased()
        guard fingerprint.hasPrefix("sha256:") else {
            throw PendingNetPairingError.invalidFingerprint
        }
        let hex = fingerprint.dropFirst("sha256:".count)
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            throw PendingNetPairingError.invalidFingerprint
        }
        guard enrollment.token.count >= 32 else {
            throw PendingNetPairingError.invalidToken
        }
        guard now < enrollment.expiresAt else {
            throw PendingNetPairingError.expired
        }
    }
}

public enum PendingNetPairingError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case missingIdentity
    case invalidEndpoint
    case invalidFingerprint
    case invalidToken
    case expired
    case unexpectedFields
    case invalidLink
    case invalidServerResponse
    case serverRejected(String)
    case keychain(OSStatus)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "不支持的配对文件格式：\(format)"
        case .unsupportedVersion(let version): "不支持的配对文件版本：\(version)"
        case .missingIdentity: "配对文件缺少 VPS 身份"
        case .invalidEndpoint: "PendingNet Server 地址无效"
        case .invalidFingerprint: "PendingNet Server 证书指纹无效"
        case .invalidToken: "配对令牌无效"
        case .expired: "配对文件已过期，请在 VPS 上重新生成"
        case .unexpectedFields: "配对文件字段不完整或包含当前版本不认识的内容"
        case .invalidLink: "这不是一条 PendingNet 配对链接，请复制完整的 pendingnet:// 链接再试"
        case .invalidServerResponse: "PendingNet Server 返回了无效响应"
        case .serverRejected(let message): message
        case .keychain(let status): "保存 VPS 凭据失败（Keychain \(status)）"
        case .transport(let message): "PendingNet Server 连接失败：\(message)"
        }
    }
}

public struct PendingNetEnrollmentResult: Codable, Equatable, Sendable {
    public var deviceID: String
    public var accessToken: String
    public var server: Server

    public struct Server: Codable, Equatable, Sendable {
        public var apiVersion: Int
        public var serverID: String
        public var name: String
        public var capabilities: [String]

        enum CodingKeys: String, CodingKey {
            case name, capabilities
            case apiVersion = "api_version"
            case serverID = "server_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case server
        case deviceID = "device_id"
        case accessToken = "access_token"
    }
}

/// Connection material returned only after a device has consumed a pairing
/// grant. This is deliberately separate from PendingNetPairingFile.
public struct PendingNetNodeProfile: Codable, Equatable, Sendable {
    public var version: Int
    public var serverID: String
    public var updatedAt: String
    public var protocols: [NodeProtocol]

    public struct NodeProtocol: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var type: String
        public var displayName: String
        public var vlessReality: VLESSReality?
        public var hysteria2: Hysteria2?

        enum CodingKeys: String, CodingKey {
            case id, type
            case displayName = "display_name"
            case vlessReality = "vless_reality"
            case hysteria2
        }
    }

    public struct VLESSReality: Codable, Equatable, Sendable {
        public var server: String
        public var serverPort: Int
        public var uuid: String
        public var flow: String
        public var serverName: String
        public var publicKey: String
        public var shortID: String

        enum CodingKeys: String, CodingKey {
            case server, uuid, flow
            case serverPort = "server_port"
            case serverName = "server_name"
            case publicKey = "public_key"
            case shortID = "short_id"
        }
    }

    public struct Hysteria2: Codable, Equatable, Sendable {
        public var server: String
        public var serverPort: Int
        public var password: String
        public var obfsType: String
        public var obfsPassword: String
        public var serverName: String
        public var certificatePublicKeySHA256: String

        enum CodingKeys: String, CodingKey {
            case server, password
            case serverPort = "server_port"
            case obfsType = "obfs_type"
            case obfsPassword = "obfs_password"
            case serverName = "server_name"
            case certificatePublicKeySHA256 = "certificate_public_key_sha256"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, protocols
        case serverID = "server_id"
        case updatedAt = "updated_at"
    }
}

public struct PendingNetServerClient: Sendable {
    private let endpoint: String
    private let certificateSHA256: String
    private let accessToken: String
    private let injectedSession: URLSession?

    public init(
        endpoint: String,
        certificateSHA256: String,
        accessToken: String,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.certificateSHA256 = certificateSHA256
        self.accessToken = accessToken
        injectedSession = session
    }

    public func nodeProfile() async throws -> PendingNetNodeProfile {
        guard let baseURL = URL(string: endpoint) else {
            throw PendingNetPairingError.invalidEndpoint
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/node"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let injectedSession {
            let (data, response) = try await injectedSession.data(for: request)
            return try decodeNodeProfile(data: data, response: response)
        }
        let response = try await PendingNetPinnedHTTPClient(
            endpoint: endpoint,
            certificateSHA256: certificateSHA256
        ).request(path: "/v1/node", method: "GET", authorization: "Bearer \(accessToken)")
        return try decodeNodeProfile(data: response.body, statusCode: response.statusCode)
    }

    private func decodeNodeProfile(data: Data, response: URLResponse) throws -> PendingNetNodeProfile {
        guard let http = response as? HTTPURLResponse else {
            throw PendingNetPairingError.invalidServerResponse
        }
        return try decodeNodeProfile(data: data, statusCode: http.statusCode)
    }

    private func decodeNodeProfile(data: Data, statusCode: Int) throws -> PendingNetNodeProfile {
        guard statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).message)
                ?? "读取 VPS 节点资料失败（HTTP \(statusCode)）"
            throw PendingNetPairingError.serverRejected(message)
        }
        let profile = try JSONDecoder().decode(PendingNetNodeProfile.self, from: data)
        guard profile.version == 1, !profile.serverID.isEmpty, !profile.protocols.isEmpty else {
            throw PendingNetPairingError.invalidServerResponse
        }
        return profile
    }

    private struct ServerError: Decodable {
        var message: String
    }
}

public struct PendingNetEnrollmentClient: Sendable {
    private let injectedSession: URLSession?

    public init(session: URLSession? = nil) {
        injectedSession = session
    }

    public func enroll(
        pairing: PendingNetPairingFile,
        deviceName: String,
        now: Date = Date()
    ) async throws -> PendingNetEnrollmentResult {
        try pairing.validate(now: now)
        guard let baseURL = URL(string: pairing.control.endpoint) else {
            throw PendingNetPairingError.invalidEndpoint
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/enroll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "token": pairing.enrollment.token,
            "device_name": deviceName,
        ])

        if let injectedSession {
            let (data, response) = try await injectedSession.data(for: request)
            return try decodeEnrollment(data: data, response: response, pairing: pairing)
        }
        let response = try await PendingNetPinnedHTTPClient(
            endpoint: pairing.control.endpoint,
            certificateSHA256: pairing.control.certificateSHA256
        ).request(path: "/v1/enroll", method: "POST", body: request.httpBody)
        return try decodeEnrollment(
            data: response.body,
            statusCode: response.statusCode,
            pairing: pairing
        )
    }

    private func decodeEnrollment(
        data: Data,
        response: URLResponse,
        pairing: PendingNetPairingFile
    ) throws -> PendingNetEnrollmentResult {
        guard let http = response as? HTTPURLResponse else {
            throw PendingNetPairingError.invalidServerResponse
        }
        return try decodeEnrollment(data: data, statusCode: http.statusCode, pairing: pairing)
    }

    private func decodeEnrollment(
        data: Data,
        statusCode: Int,
        pairing: PendingNetPairingFile
    ) throws -> PendingNetEnrollmentResult {
        guard statusCode == 201 else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).message)
                ?? "PendingNet Server 拒绝配对（HTTP \(statusCode)）"
            throw PendingNetPairingError.serverRejected(message)
        }
        let result = try JSONDecoder().decode(PendingNetEnrollmentResult.self, from: data)
        guard result.server.serverID == pairing.serverID,
              !result.deviceID.isEmpty, !result.accessToken.isEmpty else {
            throw PendingNetPairingError.invalidServerResponse
        }
        return result
    }

    private struct ServerError: Decodable {
        var message: String
    }
}

// 设备令牌的钥匙串读写见 PendingNetCredentialStore.swift。
