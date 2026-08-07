import Foundation

/// 客户端拥有的分流策略。服务端节点资料不参与这个选择。
public enum PendingNetRouteMode: String, Codable, Sendable, CaseIterable {
    case global
    case bypassCN
    case direct
}

/// 生成 iOS Packet Tunnel 用的完整 sing-box 配置。
///
/// 与 macOS 的 PendingNetProxyOnlyConfig 平级：inbound、route、dns、rule_set
/// 全部由本函数生成，`/v1/node` 只经由 runtimeServer 贡献协议 outbounds。
public enum PendingNetTunnelConfig {
    static let tunTag = "pendingnet-tun"
    static let tunAddresses = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
    static let tunMTU = 9000

    public static func make(
        runtimeServer: PendingNetRuntimeServer,
        routeMode: PendingNetRouteMode,
        ruleSetDirectory: String,
        cachePath: String
    ) throws -> Data {
        guard routeMode == .global else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        guard !cachePath.isEmpty, !ruleSetDirectory.isEmpty else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }

        let (proxyOutbounds, protocolTags) = try managedOutbounds(runtimeServer)
        let mixTag = runtimeServer.selectorTag + "-mix"

        var outbounds: [[String: Any]] = proxyOutbounds
        outbounds.append(["type": "urltest", "tag": mixTag, "outbounds": protocolTags])
        outbounds.append([
            "type": "selector",
            "tag": runtimeServer.selectorTag,
            "outbounds": protocolTags + [mixTag],
        ])
        outbounds.append(["type": "direct", "tag": "direct"])

        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": [[
                "type": "tun",
                "tag": tunTag,
                "address": tunAddresses,
                "mtu": tunMTU,
                "auto_route": true,
                "strict_route": false,
                "stack": "gvisor",
            ]],
            "outbounds": outbounds,
            "route": [
                "auto_detect_interface": true,
                "final": runtimeServer.selectorTag,
                "rules": [["action": "sniff"]],
            ],
            "experimental": [
                "cache_file": ["enabled": true, "path": cachePath],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }

    /// 解出受管协议 outbounds，并校验它们只带本 VPS 的 tag 前缀。
    static func managedOutbounds(
        _ runtimeServer: PendingNetRuntimeServer
    ) throws -> ([[String: Any]], [String]) {
        guard runtimeServer.selectorTag.hasPrefix("pendingnet-"),
              let managed = try JSONSerialization.jsonObject(with: runtimeServer.proxyOutbounds)
              as? [[String: Any]],
              !managed.isEmpty else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        let prefix = runtimeServer.selectorTag + "-"
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
