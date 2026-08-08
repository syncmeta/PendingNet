import Foundation

/// 客户端拥有的分流策略。服务端节点资料不参与这个选择。
///
/// 三档与 macOS 一字不差（全局 / 白名单 / 黑名单，见 ControlView）。iOS 早先
/// 叫「全局代理 / 绕过大陆 / 全局直连」：「绕过大陆」和 macOS 的「白名单」是
/// 同一件事的两个名字，还多出一档全直连——要直连断开 VPN 就是了，留着只会
/// 让人以为两端功能不一样。旧值的读法见 `stored(rawValue:)`。
public enum PendingNetRouteMode: String, Codable, Sendable, CaseIterable {
    /// 全部流量走代理。
    case global
    /// 国内直连、境外走代理。
    case whitelist
    /// 只有被墙的域名走代理，其余直连。
    case blacklist

    /// 读磁盘上存着的原始值，含旧命名。
    ///
    /// 改枚举名不能让老用户的设置读成 nil 而被打回默认值：`bypassCN` 就是
    /// 现在的白名单，`direct`（全局直连）那一档已经取消，落到全局——把
    /// 「本来在走代理的人」放到全局比放到别处更接近他原来的处境。
    public static func stored(rawValue raw: String) -> PendingNetRouteMode? {
        if let mode = PendingNetRouteMode(rawValue: raw) { return mode }
        switch raw {
        case "bypassCN": return .whitelist
        case "direct": return .global
        default: return nil
        }
    }
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

    /// 一个规则集：配置里的 tag（同时也是落盘文件名 `<name>.srs`），以及主
    /// App 下载它的来源。
    ///
    /// 名字与下载地址必须待在同一条记录里。早先名单在 SBTallyCore、地址在
    /// App 侧的下载器，两处各写各的——只要有一边多/少一个名字，表现就是
    /// sing-box 启动时报 `rule-set not found`，而且要到真机上才看得见。
    ///
    /// 上游文件名不一定等于我们用的 tag（gfw 那份上游就叫 `gfw.srs`），所以
    /// 落盘一律按 `name` 重命名，不跟着 URL 走。
    public struct RuleSetSource: Sendable, Equatable {
        public let name: String
        public let url: URL
    }

    /// 全项目唯一一份规则集名单。扩展按 `type: local` 读同名 `.srs` 文件，
    /// 主 App 的下载器按同一份名单取文件。来源与 macOS 侧同一批
    /// （见 `app/SBTally/PendingNetRouteRuleSets.swift`），不另发明一套。
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
        RuleSetSource(
            name: "geosite-gfw",
            url: URL(
                string: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs"
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

    /// 各档位真正引用到的规则集。只把用得上的写进配置：全局一个都不要，
    /// 白名单看国内名单，黑名单看 GFW 名单。
    static func ruleSetTags(mode: PendingNetRouteMode) -> [String] {
        switch mode {
        case .global: []
        case .whitelist: ["geoip-cn", "geosite-cn"]
        case .blacklist: ["geosite-gfw"]
        }
    }

    static func ruleSets(directory: String, mode: PendingNetRouteMode) -> [[String: Any]] {
        ruleSetTags(mode: mode).map { name in
            [
                "type": "local",
                "tag": name,
                "format": "binary",
                "path": (directory as NSString).appendingPathComponent("\(name).srs"),
            ]
        }
    }

    /// route.final：黑名单的兜底是直连，另外两档兜底走代理。
    static func routeFinal(mode: PendingNetRouteMode, selectorTag: String) -> String {
        mode == .blacklist ? "direct" : selectorTag
    }

    static func routeRules(mode: PendingNetRouteMode, selectorTag: String) -> [[String: Any]] {
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        switch mode {
        case .global:
            break
        case .whitelist:
            // 国内直连、境外走代理：命中就直连，剩下的交给 final（selector）。
            rules.append(["ip_is_private": true, "outbound": "direct"])
            rules.append(["rule_set": ["geosite-cn"], "outbound": "direct"])
            rules.append(["rule_set": ["geoip-cn"], "outbound": "direct"])
        case .blacklist:
            // 只有被墙的域名走代理，剩下的交给 final（direct）。
            rules.append(["ip_is_private": true, "outbound": "direct"])
            rules.append(["rule_set": ["geosite-gfw"], "outbound": selectorTag])
        }
        return rules
    }

    /// `route.default_domain_resolver` 必须跟着分流模式走，而不是永远钉在
    /// dns-proxy：黑名单下绝大多数流量是直连的，解析若仍走代理侧，等于让
    /// 每一次直连都先绕代理一趟；被墙的那些域名由 dns.rules 单独摘出来。
    static func defaultDomainResolver(mode: PendingNetRouteMode) -> String {
        mode == .blacklist ? "dns-direct" : "dns-proxy"
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
            "final": mode == .blacklist ? "dns-direct" : "dns-proxy",
            // A+AAAA 双查会让 goroutine 数直接翻倍，实测中这是主要放大器。
            "strategy": "ipv4_only",
            "disable_cache": false,
            "independent_cache": false,
        ]
        switch mode {
        case .global:
            break
        case .whitelist:
            // 国内域名必须用直连解析器，否则分流判断本身要先过一次代理。
            section["rules"] = [["rule_set": ["geosite-cn"], "server": "dns-direct"]]
        case .blacklist:
            // 反过来：默认直连解析，被墙的那些域名交给代理侧解析，否则拿到的
            // 就是被污染的结果。
            section["rules"] = [["rule_set": ["geosite-gfw"], "server": "dns-proxy"]]
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
            "final": routeFinal(mode: routeMode, selectorTag: runtimeServer.selectorTag),
            // sing-box 1.12+ 起，配置 2 个及以上 DNS server 时必须显式声明
            // default_domain_resolver（省略即校验失败）。这个字段跟着分流
            // 模式走，见 defaultDomainResolver(mode:)。
            "default_domain_resolver": defaultDomainResolver(mode: routeMode),
            "rules": routeRules(mode: routeMode, selectorTag: runtimeServer.selectorTag),
        ]
        let sets = ruleSets(directory: ruleSetDirectory, mode: routeMode)
        if !sets.isEmpty { route["rule_set"] = sets }

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
