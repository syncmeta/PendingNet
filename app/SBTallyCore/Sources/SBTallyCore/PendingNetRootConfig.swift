import Foundation

/// macOS 的 TUN / 系统代理两种接管方式共用的 root 引擎基线配置。
///
/// 配对文件只带 VPS 协议出站；本机入站、DNS、路由、Clash 控制口和缓存位置都由
/// 客户端自己生成。此前这两份基线只能靠 `deploy/install.sh` 预先放进
/// `/usr/local/etc/sbtally`，所以一台从未跑过老脚本的新 Mac 即使已经授权助手，
/// 仍然会在第一次切到 TUN / 系统代理时找不到配置。
public enum PendingNetRootConfig {
    public static let tunFilename = "master-tun.json"
    public static let noTunFilename = "master-notun.json"
    public static let activeFilename = "master.json"
    public static let secretFilename = "control-secret"
    public static let cacheFilename = "cache.db"
    public static let systemDNSTag = "pendingnet-system-dns"

    /// 生成一份还没有 VPS 的基线。`proxy` 暂时只含 `direct`；第一次应用配对资料时，
    /// `PendingNetLocalConfigComposer` 会把真实 VPS selector 放到最前面。
    public static func make(
        enableTUN: Bool,
        controlSecret: String,
        cachePath: String,
        mixedPort: Int = 2080,
        controlPort: Int = 9090
    ) throws -> Data {
        guard !controlSecret.isEmpty, !cachePath.isEmpty,
              (1024...65535).contains(mixedPort),
              (1024...65535).contains(controlPort),
              mixedPort != controlPort else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }

        var inbounds: [[String: Any]] = []
        if enableTUN {
            inbounds.append(tunInbound)
        }
        inbounds.append([
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": mixedPort,
        ])
        if enableTUN { inbounds.append(systemDNSInbound) }

        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "dns": PendingNetDNSPolicy.clashSection(tags: ["geosite-cn", "geosite-gfw"]),
            "inbounds": inbounds,
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["direct"]],
                ["type": "direct", "tag": "direct"],
            ],
            "route": [
                "auto_detect_interface": true,
                "find_process": true,
                "default_domain_resolver": PendingNetDNSPolicy.bootstrapResolver,
                "final": "proxy",
                "rules": routeRules,
                "rule_set": remoteRuleSets,
            ],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(controlPort)",
                    "secret": controlSecret,
                    "default_mode": "Whitelist",
                    "store_mode": false,
                ],
                "cache_file": ["enabled": true, "path": cachePath],
            ],
        ]
        return try encode(root)
    }

    /// 从已有配置派生 TUN / 非 TUN 变体，只改 `inbounds` 里的 TUN 那一项。
    /// 老安装如果只有 `master.json`，这样补齐两份变体不会丢掉它已有的 VPS、规则、
    /// 控制密钥或其它本机策略。
    public static func variant(from data: Data, enableTUN: Bool) throws -> Data {
        let migrated = try migratingGeneratedDNSPolicy(in: migratingLegacyLocalDNS(in: data))
        guard var root = try JSONSerialization.jsonObject(with: migrated) as? [String: Any],
              var inbounds = root["inbounds"] as? [[String: Any]] else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        inbounds.removeAll { $0["type"] as? String == "tun" }
        if enableTUN { inbounds.insert(tunInbound, at: 0) }
        root["inbounds"] = inbounds
        return try migratingSystemDNS(in: encode(root))
    }

    /// Upgrade existing root configs without replacing custom TUN/policy fields.
    public static func migratingSystemDNS(in data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var inbounds = root["inbounds"] as? [[String: Any]] else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        var route = root["route"] as? [String: Any] ?? [:]
        inbounds.removeAll { $0["tag"] as? String == systemDNSTag }
        if inbounds.contains(where: { $0["type"] as? String == "tun" }) {
            inbounds.append(systemDNSInbound)
        }
        var rules = route["rules"] as? [[String: Any]] ?? []
        rules.removeAll { $0["inbound"] as? [String] == [systemDNSTag] }
        rules.insert(systemDNSRule, at: 0)
        route["rules"] = rules
        root["route"] = route
        root["inbounds"] = inbounds
        let updated = try encode(root)
        // Keep byte identity on the next preparation pass.
        let old = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
        let new = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return old == new ? data : updated
    }

    /// Recognize the old generated split policy exactly; do not replace custom
    /// DNS rules or other route actions when upgrading existing installations.
    public static func migratingGeneratedDNSPolicy(in data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var dns = root["dns"] as? [String: Any],
              let rules = dns["rules"] as? [[String: Any]], rules.count == 1,
              Set(rules[0].keys) == Set(["rule_set", "server"]),
              (rules[0]["rule_set"] as? [String] == ["geosite-cn"] || rules[0]["rule_set"] as? String == "geosite-cn"),
              rules[0]["server"] as? String == "dns-direct",
              var route = root["route"] as? [String: Any],
              var routeRules = route["rules"] as? [[String: Any]],
              let sets = route["rule_set"] as? [[String: Any]] else { return data }
        let tags = Set(sets.compactMap { $0["tag"] as? String })
        guard tags.contains("geosite-cn"), tags.contains("geosite-gfw") else { return data }
        let oldDomestic: [String: Any] = ["rule_set": ["geosite-cn"], "action": "resolve", "server": "dns-direct", "strategy": "prefer_ipv4"]
        var oldCLI = oldDomestic
        oldCLI["rule_set"] = "geosite-cn"
        let oldFinal: [String: Any] = ["action": "resolve", "strategy": "prefer_ipv4"]
        guard let index = routeRules.indices.first(where: {
            NSDictionary(dictionary: routeRules[$0]).isEqual(to: oldDomestic) || NSDictionary(dictionary: routeRules[$0]).isEqual(to: oldCLI)
        }), index + 1 < routeRules.count,
        NSDictionary(dictionary: routeRules[index + 1]).isEqual(to: oldFinal) else { return data }
        routeRules.replaceSubrange(index...index + 1, with: PendingNetDNSPolicy.resolveRules(tags: tags))
        dns["rules"] = PendingNetDNSPolicy.clashRules(tags: tags)
        dns["independent_cache"] = true
        route["rules"] = routeRules
        let resolver = route["default_domain_resolver"] as? [String: Any]
        if resolver?["server"] as? String == "dns-proxy", Set(resolver!.keys).isSubset(of: ["server", "strategy"]) {
            route["default_domain_resolver"] = PendingNetDNSPolicy.bootstrapResolver
        }
        root["dns"] = dns
        root["route"] = route
        return try encode(root)
    }

    /// Upgrade only the exact local/UDP resolvers generated by older versions.
    /// Custom upstreams, TLS options and routing remain owned by their editor.
    public static func migratingLegacyLocalDNS(in data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        guard var dns = root["dns"] as? [String: Any],
              var servers = dns["servers"] as? [[String: Any]] else { return data }
        var changed = false
        for index in servers.indices {
            let server = servers[index]
            let oldLocal = server["type"] as? String == "local"
                && server["tag"] as? String == "dns-local"
                && Set(server.keys) == Set(["type", "tag"])
            let oldUDP = server["type"] as? String == "udp"
                && server["tag"] as? String == "dns-direct"
                && server["server"] as? String == "223.5.5.5"
                && server["server_port"] as? Int == 53
                && Set(server.keys) == Set(["type", "tag", "server", "server_port"])
            if oldLocal || oldUDP {
                servers[index] = PendingNetDNSPolicy.directServer
                changed = true
            }
        }
        guard changed else { return data }
        dns["servers"] = servers
        if var rules = dns["rules"] as? [[String: Any]] {
            for index in rules.indices where rules[index]["server"] as? String == "dns-local" {
                rules[index]["server"] = "dns-direct"
            }
            dns["rules"] = rules
        }
        root["dns"] = dns

        if var route = root["route"] as? [String: Any],
           var rules = route["rules"] as? [[String: Any]] {
            for index in rules.indices where rules[index]["server"] as? String == "dns-local" {
                rules[index]["server"] = "dns-direct"
            }
            route["rules"] = rules
            root["route"] = route
        }
        return try encode(root)
    }

    private static let tunInbound: [String: Any] = [
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30"],
        "mtu": 1500,
        "auto_route": true,
        "stack": "system",
    ]

    private static let routeRules: [[String: Any]] = [
        systemDNSRule,
        ["action": "sniff"],
        ["protocol": "dns", "action": "hijack-dns"],
    ] + PendingNetDNSPolicy.resolveRules(tags: ["geosite-cn", "geosite-gfw"]) + [
        ["rule_set": ["geosite-ads"], "action": "reject"],
        ["ip_is_private": true, "outbound": "direct"],
        ["clash_mode": "Global", "outbound": "proxy"],
        [
            "clash_mode": "Blacklist",
            "rule_set": ["geosite-gfw"],
            "outbound": "proxy",
        ],
        ["clash_mode": "Blacklist", "outbound": "direct"],
        [
            "clash_mode": "Whitelist",
            "rule_set": ["geoip-cn", "geosite-cn"],
            "outbound": "direct",
        ],
        [
            "clash_mode": "Whitelist",
            "rule_set": ["geosite-noncn"],
            "outbound": "proxy",
        ],
    ]

    private static let systemDNSInbound: [String: Any] = [
        "type": "direct", "tag": systemDNSTag,
        "listen": "127.0.0.1", "listen_port": 53,
    ]
    private static let systemDNSRule: [String: Any] = [
        "inbound": [systemDNSTag], "action": "hijack-dns",
    ]

    private static let remoteRuleSets: [[String: Any]] = [
        remoteRuleSet(
            tag: "geosite-cn",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
        ),
        remoteRuleSet(
            tag: "geoip-cn",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
        ),
        remoteRuleSet(
            tag: "geosite-noncn",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
        ),
        remoteRuleSet(
            tag: "geosite-ads",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"
        ),
        remoteRuleSet(
            tag: "geosite-gfw",
            url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs"
        ),
    ]

    private static func remoteRuleSet(tag: String, url: String) -> [String: Any] {
        [
            "type": "remote",
            "tag": tag,
            "format": "binary",
            "url": url,
            "download_detour": "proxy",
        ]
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }
}
