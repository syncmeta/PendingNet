import CryptoKit
import Foundation

/// 粘贴框里一行可导入的内容：PendingNet 配对链接，或通用节点分享链接。
public enum PendingNetImportItem: Equatable, Sendable {
    case pairing(PendingNetPairingFile)
    case sharedNode(PendingNetSharedNode)
}

public enum PendingNetTextImportError: LocalizedError, Equatable {
    case empty
    case unsupportedLink(line: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "请粘贴至少一条节点链接"
        case .unsupportedLink(let line):
            "第 \(line) 行不是支持的节点链接（支持 pendingnet://、vless://、hysteria2:// 和 hy2://）"
        }
    }
}

public enum PendingNetTextImport {
    /// 一行一个节点；空行忽略。先把所有行完整解析成功，调用方再开始写存储或消费
    /// 一次性配对令牌，避免格式错误发生在中途时留下半批结果。
    public static func decode(_ text: String, now: Date = Date()) throws -> [PendingNetImportItem] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
        var items: [PendingNetImportItem] = []
        for (offset, rawLine) in lines.enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            do {
                if line.lowercased().hasPrefix("pendingnet://") {
                    items.append(.pairing(try PendingNetPairingFile.decode(link: line, now: now)))
                } else {
                    items.append(.sharedNode(try PendingNetSharedNode.decode(link: line)))
                }
            } catch {
                throw PendingNetTextImportError.unsupportedLink(line: offset + 1)
            }
        }
        guard !items.isEmpty else { throw PendingNetTextImportError.empty }
        return items
    }
}

/// VLESS Reality / Hysteria2 的标准分享链接。原链接包含节点密钥，只交给调用方
/// 存入 Keychain；普通 VPS 记录只保存展示与路由所需的非敏感字段。
public struct PendingNetSharedNode: Equatable, Sendable {
    public static let capability = "shared-node-link"

    public let originalLink: String
    public let record: PairedVPSRecord
    public let profile: PendingNetNodeProfile

    public static func decode(link: String) throws -> Self {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/"
        else { throw PendingNetTextImportError.unsupportedLink(line: 1) }
        let port = components.port ?? 443
        guard (1...65535).contains(port) else {
            throw PendingNetTextImportError.unsupportedLink(line: 1)
        }

        let scheme = rawScheme == "hy2" ? "hysteria2" : rawScheme
        let query = queryValues(components)
        let serverID = "share-" + SHA256.hash(data: Data(trimmed.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        let name = decodedFragment(components) ?? host
        let protocolItem: PendingNetNodeProfile.NodeProtocol

        switch scheme {
        case "vless":
            guard let uuid = decodedUser(components), !uuid.isEmpty,
                  query["security"]?.lowercased() == "reality",
                  let serverName = query["sni"], !serverName.isEmpty,
                  let publicKey = query["pbk"] ?? query["publickey"], !publicKey.isEmpty
            else { throw PendingNetTextImportError.unsupportedLink(line: 1) }
            protocolItem = .init(
                id: "reality",
                type: "vless-reality",
                displayName: "Reality",
                vlessReality: .init(
                    server: host,
                    serverPort: port,
                    uuid: uuid,
                    flow: query["flow"] ?? "",
                    serverName: serverName,
                    publicKey: publicKey,
                    shortID: query["sid"] ?? query["shortid"] ?? ""
                ),
                hysteria2: nil
            )
        case "hysteria2":
            guard let password = decodedUser(components), !password.isEmpty else {
                throw PendingNetTextImportError.unsupportedLink(line: 1)
            }
            protocolItem = .init(
                id: "hy2",
                type: "hysteria2",
                displayName: "Hysteria2",
                vlessReality: nil,
                hysteria2: .init(
                    server: host,
                    serverPort: port,
                    password: password,
                    obfsType: query["obfs"] ?? "",
                    obfsPassword: query["obfs-password"] ?? query["obfspassword"] ?? "",
                    serverName: query["sni"] ?? host,
                    certificatePublicKeySHA256: query["pinsha256"] ?? ""
                )
            )
        default:
            throw PendingNetTextImportError.unsupportedLink(line: 1)
        }

        let profile = PendingNetNodeProfile(
            version: 1,
            serverID: serverID,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            protocols: [protocolItem]
        )
        var record = PairedVPSRecord(
            serverID: serverID,
            name: name,
            endpoint: "https://\(host):\(port)",
            certificateSHA256: "",
            deviceID: Self.capability,
            capabilities: [Self.capability],
            nodeProtocols: [protocolItem.type]
        )
        record.adoptProxyEntry(from: profile)
        return Self(originalLink: trimmed, record: record, profile: profile)
    }

    public func runtimeServer() throws -> PendingNetRuntimeServer {
        try profile.runtimeServer(name: record.name)
    }

    private static func queryValues(_ components: URLComponents) -> [String: String] {
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name.lowercased()] == nil {
            values[item.name.lowercased()] = item.value ?? ""
        }
        return values
    }

    private static func decodedUser(_ components: URLComponents) -> String? {
        components.percentEncodedUser?.removingPercentEncoding ?? components.user
    }

    private static func decodedFragment(_ components: URLComponents) -> String? {
        guard let fragment = components.percentEncodedFragment?.removingPercentEncoding,
              !fragment.isEmpty else { return nil }
        return fragment
    }
}

public extension PairedVPSRecord {
    var isSharedNode: Bool { capabilities.contains(PendingNetSharedNode.capability) }
}
