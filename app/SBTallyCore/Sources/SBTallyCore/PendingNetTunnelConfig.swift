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

    /// 代理侧解析器。走 selector，随隧道一起生效。
    static let proxyDNSServer = "1.1.1.1"
    /// 直连侧解析器。走 direct，用于分流模式下的国内域名。
    static let directDNSServer = "223.5.5.5"

    static func dnsSection(selectorTag: String) -> [String: Any] {
        [
            "servers": [
                [
                    "type": "https",
                    "tag": "dns-proxy",
                    "server": proxyDNSServer,
                    "detour": selectorTag,
                ],
                [
                    "type": "https",
                    "tag": "dns-direct",
                    "server": directDNSServer,
                    "detour": "direct",
                ],
            ],
            "final": "dns-proxy",
            // A+AAAA 双查会让 goroutine 数直接翻倍，实测中这是主要放大器。
            "strategy": "ipv4_only",
            "disable_cache": false,
            "independent_cache": false,
        ]
    }

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

        let (proxyOutbounds, protocolTags) = try runtimeServer.managedProxyOutbounds()
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
                // sing-box 1.12+ 弃用了"省略即隐式走 dns.rules"的旧行为；
                // 显式指到 dns-direct，避免代理侧解析器反过来要靠自己解析自己。
                "default_domain_resolver": "dns-direct",
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"],
                ],
            ],
            "dns": dnsSection(selectorTag: runtimeServer.selectorTag),
            "experimental": [
                "cache_file": ["enabled": true, "path": cachePath],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }
}
