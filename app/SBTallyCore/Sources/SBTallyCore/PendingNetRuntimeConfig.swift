import CryptoKit
import Foundation

public enum PendingNetRuntimeConfigError: LocalizedError, Equatable {
    case unsupportedProtocol(String)
    case malformedProtocol(String)
    case invalidLocalConfiguration
    case missingProxySelector

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocol(let type): "PendingNet 不支持节点协议：\(type)"
        case .malformedProtocol(let id): "VPS 返回的节点协议资料不完整：\(id)"
        case .invalidLocalConfiguration: "本机 sing-box 配置格式无效"
        case .missingProxySelector: "本机 sing-box 配置缺少 proxy 选择器"
        }
    }
}

public struct PendingNetRuntimeServer: Sendable, Equatable {
    public var serverID: String
    public var name: String
    public var selectorTag: String
    public var proxyOutbounds: Data

    public init(serverID: String, name: String, selectorTag: String, proxyOutbounds: Data) {
        self.serverID = serverID
        self.name = name
        self.selectorTag = selectorTag
        self.proxyOutbounds = proxyOutbounds
    }

    /// The sing-box selector tag a given VPS always maps to. Derived purely from
    /// the server ID so the GUI can match an applied tag back to a paired VPS
    /// without asking the server for its node profile again.
    public static func selectorTag(forServerID serverID: String) -> String {
        let digest = SHA256.hash(data: Data(serverID.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "pendingnet-\(suffix)"
    }
}

extension PendingNetRuntimeServer {
    /// Validates the selector tag and parses this VPS's managed proxy outbounds.
    /// Shared by every platform composer so the tag-safety and outbound-shape
    /// checks can't silently drift between them.
    func managedProxyOutbounds() throws -> (outbounds: [[String: Any]], tags: [String]) {
        guard selectorTag.hasPrefix("pendingnet-"),
              selectorTag.count <= 64,
              selectorTag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let managed = try JSONSerialization.jsonObject(with: proxyOutbounds) as? [[String: Any]],
              !managed.isEmpty else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        let prefix = selectorTag + "-"
        var tags: [String] = []
        for outbound in managed {
            guard let type = outbound["type"] as? String,
                  type == "vless" || type == "hysteria2",
                  let tag = outbound["tag"] as? String,
                  tag.hasPrefix(prefix),
                  !tags.contains(tag) else {
                throw PendingNetRuntimeConfigError.invalidLocalConfiguration
            }
            tags.append(tag)
        }
        return (managed, tags)
    }
}

public extension PendingNetNodeProfile {
    /// Produces only sing-box proxy outbounds. DNS, routes, TUN, selectors and
    /// all other client policy are intentionally composed by each platform.
    func singBoxProxyOutbounds(tagPrefix: String) throws -> Data {
        let outbounds: [[String: Any]] = try protocols.map { item in
            let tag = "\(tagPrefix)-\(item.id)"
            switch item.type {
            case "vless-reality":
                guard let node = item.vlessReality else {
                    throw PendingNetRuntimeConfigError.malformedProtocol(item.id)
                }
                return [
                    "type": "vless",
                    "tag": tag,
                    "server": node.server,
                    "server_port": node.serverPort,
                    "uuid": node.uuid,
                    "flow": node.flow,
                    "tls": [
                        "enabled": true,
                        "server_name": node.serverName,
                        "reality": [
                            "enabled": true,
                            "public_key": node.publicKey,
                            "short_id": node.shortID,
                        ],
                        "utls": ["enabled": true, "fingerprint": "chrome"],
                    ],
                ]
            case "hysteria2":
                guard let node = item.hysteria2 else {
                    throw PendingNetRuntimeConfigError.malformedProtocol(item.id)
                }
                return [
                    "type": "hysteria2",
                    "tag": tag,
                    "server": node.server,
                    "server_port": node.serverPort,
                    "password": node.password,
                    "obfs": ["type": node.obfsType, "password": node.obfsPassword],
                    "tls": [
                        "enabled": true,
                        "server_name": node.serverName,
                        "insecure": true,
                        "certificate_public_key_sha256": [node.certificatePublicKeySHA256],
                    ],
                ]
            default:
                throw PendingNetRuntimeConfigError.unsupportedProtocol(item.type)
            }
        }
        return try JSONSerialization.data(withJSONObject: outbounds, options: [.sortedKeys])
    }

    func runtimeServer(name: String) throws -> PendingNetRuntimeServer {
        let selectorTag = PendingNetRuntimeServer.selectorTag(forServerID: serverID)
        return PendingNetRuntimeServer(
            serverID: serverID,
            name: name,
            selectorTag: selectorTag,
            proxyOutbounds: try singBoxProxyOutbounds(tagPrefix: selectorTag)
        )
    }
}

/// Merges one PendingNet-managed VPS into a platform-owned sing-box config.
/// DNS, route, TUN, rule-set and application policy fields are carried over
/// verbatim. Only the matching managed VPS outbounds and the top-level proxy
/// selector membership are changed.
public enum PendingNetLocalConfigComposer {
    public static func merge(
        baseConfig: Data,
        runtimeServer: PendingNetRuntimeServer
    ) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: baseConfig) as? [String: Any],
              var existing = root["outbounds"] as? [[String: Any]] else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        let (managed, protocolTags) = try runtimeServer.managedProxyOutbounds()

        let prefix = runtimeServer.selectorTag + "-"
        let mixTag = runtimeServer.selectorTag + "-mix"
        existing.removeAll { outbound in
            guard let tag = outbound["tag"] as? String else { return false }
            return tag == runtimeServer.selectorTag || tag.hasPrefix(prefix)
        }
        existing.append(contentsOf: managed)
        existing.append([
            "type": "urltest",
            "tag": mixTag,
            "outbounds": protocolTags,
        ])
        existing.append([
            "type": "selector",
            "tag": runtimeServer.selectorTag,
            "outbounds": protocolTags + [mixTag],
        ])

        guard let proxyIndex = existing.firstIndex(where: {
            ($0["type"] as? String) == "selector" && ($0["tag"] as? String) == "proxy"
        }), var proxyMembers = existing[proxyIndex]["outbounds"] as? [String] else {
            throw PendingNetRuntimeConfigError.missingProxySelector
        }
        proxyMembers.removeAll { $0 == runtimeServer.selectorTag }
        proxyMembers.insert(runtimeServer.selectorTag, at: 0)
        existing[proxyIndex]["outbounds"] = proxyMembers

        root["outbounds"] = existing
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }
}

/// Builds the client-owned baseline used by macOS "local port" mode.
/// Pairing material is merged into this document later; the pairing file never
/// supplies inbounds, routes, DNS policy, the control secret, or cache paths.
public enum PendingNetProxyOnlyConfig {
    public static func make(
        controlSecret: String,
        cachePath: String,
        listenPort: Int = 2080,
        controlPort: Int = 29090
    ) throws -> Data {
        guard !controlSecret.isEmpty, !cachePath.isEmpty,
              (1024...65535).contains(listenPort),
              (1024...65535).contains(controlPort),
              listenPort != controlPort else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": [[
                "type": "mixed",
                "tag": "pendingnet-local",
                "listen": "127.0.0.1",
                "listen_port": listenPort,
            ]],
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["direct"]],
                ["type": "direct", "tag": "direct"],
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy",
                "rules": [
                    ["action": "sniff"],
                    ["clash_mode": "Direct", "outbound": "direct"],
                    ["clash_mode": "Global", "outbound": "proxy"],
                ],
            ],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(controlPort)",
                    "secret": controlSecret,
                    "default_mode": "Global",
                ],
                "cache_file": ["enabled": true, "path": cachePath],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }
}
