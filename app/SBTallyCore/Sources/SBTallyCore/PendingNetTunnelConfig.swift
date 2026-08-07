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

    /// 一个规则集：配置里的 tag / 文件名，以及主 App 下载它的来源。
    ///
    /// 名字与下载地址必须待在同一条记录里。早先名单在 SBTallyCore、地址在
    /// App 侧的下载器，两处各写各的——只要有一边多/少一个名字，表现就是
    /// sing-box 启动时报 `rule-set not found`，而且要到真机上才看得见。
    public struct RuleSetSource: Sendable, Equatable {
        public let name: String
        public let url: URL
    }

    /// 全项目唯一一份规则集名单。扩展按 `type: local` 读同名 `.srs` 文件，
    /// 主 App 的下载器按同一份名单取文件。
    public static let requiredRuleSets: [RuleSetSource] = [
        RuleSetSource(
            name: "geoip-cn",
            url: URL(
                string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
            )!
        ),
        RuleSetSource(
            name: "geosite-cn",
            url: URL(
                string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
            )!
        ),
    ]

    public static var requiredRuleSetNames: [String] { requiredRuleSets.map(\.name) }

    /// `.srs` 二进制的魔数（sing-box `common/srs/binary.go` 的 `MagicBytes`）。
    /// 只按大小判断是不够的：`raw.githubusercontent.com` 在大陆网络下不可达，
    /// 中间设备返回一个 200 + HTML 的门户页完全可能，那种文件大小非零、
    /// 状态码正常，落地之后要到 sing-box 解析时才炸。
    public static let ruleSetMagicBytes: [UInt8] = [0x53, 0x52, 0x53] // "SRS"

    /// 文件是否像一个真正的 `.srs`。只看头三个字节——完整校验是 sing-box
    /// 自己的事，这里要挡的是「根本不是 srs」这一类。
    public static func looksLikeRuleSet(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: ruleSetMagicBytes.count) else { return false }
        return Array(head) == ruleSetMagicBytes
    }

    static func ruleSets(directory: String) -> [[String: Any]] {
        requiredRuleSetNames.map { name in
            [
                "type": "local",
                "tag": name,
                "format": "binary",
                "path": (directory as NSString).appendingPathComponent("\(name).srs"),
            ]
        }
    }

    static func routeRules(mode: PendingNetRouteMode) -> [[String: Any]] {
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if mode == .bypassCN {
            rules.append(["ip_is_private": true, "outbound": "direct"])
            rules.append(["rule_set": ["geosite-cn"], "outbound": "direct"])
            rules.append(["rule_set": ["geoip-cn"], "outbound": "direct"])
        }
        return rules
    }

    /// `route.default_domain_resolver` 必须跟着分流模式走，而不是永远钉在
    /// dns-proxy：.direct 是应急全直连，若解析仍指向 dns-proxy，等于把
    /// 应急模式下的域名解析又绕回代理，和该模式的意义相悖。
    static func defaultDomainResolver(mode: PendingNetRouteMode) -> String {
        mode == .direct ? "dns-direct" : "dns-proxy"
    }

    static func dnsSection(selectorTag: String, mode: PendingNetRouteMode) -> [String: Any] {
        var section: [String: Any] = [
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
            "final": mode == .direct ? "dns-direct" : "dns-proxy",
            // A+AAAA 双查会让 goroutine 数直接翻倍，实测中这是主要放大器。
            "strategy": "ipv4_only",
            "disable_cache": false,
            "independent_cache": false,
        ]
        if mode == .bypassCN {
            section["rules"] = [["rule_set": ["geosite-cn"], "server": "dns-direct"]]
        }
        return section
    }

    public static func make(
        runtimeServer: PendingNetRuntimeServer,
        routeMode: PendingNetRouteMode,
        ruleSetDirectory: String,
        cachePath: String
    ) throws -> Data {
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

        var route: [String: Any] = [
            "auto_detect_interface": true,
            "final": routeMode == .direct ? "direct" : runtimeServer.selectorTag,
            // sing-box 1.12+ 起，配置 2 个及以上 DNS server 时必须显式声明
            // default_domain_resolver（省略即校验失败）。这个字段跟着分流
            // 模式走，见 defaultDomainResolver(mode:)。
            "default_domain_resolver": defaultDomainResolver(mode: routeMode),
            "rules": routeRules(mode: routeMode),
        ]
        if routeMode == .bypassCN {
            route["rule_set"] = ruleSets(directory: ruleSetDirectory)
        }

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
            "route": route,
            "dns": dnsSection(selectorTag: runtimeServer.selectorTag, mode: routeMode),
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
