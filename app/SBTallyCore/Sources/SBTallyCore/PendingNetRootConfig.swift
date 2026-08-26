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

        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "dns": [
                "servers": [
                    [
                        "type": "https",
                        "tag": "dns-proxy",
                        "server": "1.1.1.1",
                        "path": "/dns-query",
                        "detour": "proxy",
                    ],
                    ["type": "local", "tag": "dns-local"],
                ],
                "rules": [["rule_set": ["geosite-cn"], "server": "dns-local"]],
                "final": "dns-proxy",
                "strategy": "prefer_ipv4",
            ],
            "inbounds": inbounds,
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["direct"]],
                ["type": "direct", "tag": "direct"],
            ],
            "route": [
                "auto_detect_interface": true,
                "find_process": true,
                "default_domain_resolver": [
                    "server": "dns-proxy",
                    "strategy": "prefer_ipv4",
                ],
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
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var inbounds = root["inbounds"] as? [[String: Any]] else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        inbounds.removeAll { $0["type"] as? String == "tun" }
        if enableTUN { inbounds.insert(tunInbound, at: 0) }
        root["inbounds"] = inbounds
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
        ["action": "sniff"],
        [
            "rule_set": ["geosite-cn"],
            "action": "resolve",
            "server": "dns-local",
            "strategy": "prefer_ipv4",
        ],
        ["action": "resolve", "strategy": "prefer_ipv4"],
        ["protocol": "dns", "action": "hijack-dns"],
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
