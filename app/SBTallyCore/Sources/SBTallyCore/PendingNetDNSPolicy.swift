import Foundation

/// Client-owned DNS policy. Literal upstream addresses avoid bootstrap DNS;
/// only the proxy resolver uses the selected node. No plaintext fallback.
public enum PendingNetDNSPolicy {
    static func server(tag: String, address: String, name: String, detour: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "type": "https", "tag": tag, "server": address, "path": "/dns-query",
            "tls": ["enabled": true, "server_name": name],
        ]
        if let detour { value["detour"] = detour }
        return value
    }

    static var directServer: [String: Any] {
        server(tag: "dns-direct", address: "223.5.5.5", name: "dns.alidns.com")
    }

    static func servers(proxy: String) -> [[String: Any]] {
        [server(tag: "dns-proxy", address: "1.1.1.1", name: "cloudflare-dns.com", detour: proxy), directServer]
    }

    /// Clash mode changes must affect DNS as well as traffic routing.
    static func clashRules(tags: Set<String>) -> [[String: Any]] {
        var rules: [[String: Any]] = [
            ["clash_mode": "Global", "server": "dns-proxy"],
            ["clash_mode": "Direct", "server": "dns-direct"],
        ]
        if tags.contains("geosite-gfw") {
            rules += [
                ["clash_mode": "Blacklist", "rule_set": ["geosite-gfw"], "server": "dns-proxy"],
                ["clash_mode": "Blacklist", "server": "dns-direct"],
            ]
        }
        if tags.contains("geosite-cn") {
            rules.append(["clash_mode": "Whitelist", "rule_set": ["geosite-cn"], "server": "dns-direct"])
        }
        return rules
    }

    static func clashSection(tags: Set<String>) -> [String: Any] {
        ["servers": servers(proxy: "proxy"), "rules": clashRules(tags: tags),
         "final": "dns-proxy", "strategy": "prefer_ipv4", "independent_cache": true]
    }

    static func resolveRules(tags: Set<String>) -> [[String: Any]] {
        // Resolve is non-terminal: mutually exclusive matches prevent a later
        // proxy lookup from overwriting an earlier direct lookup.
        var direct: [[String: Any]] = [["clash_mode": "Direct"]]
        if tags.contains("geosite-gfw") {
            direct.append(["type": "logical", "mode": "and", "rules": [
                ["clash_mode": "Blacklist"], ["rule_set": ["geosite-gfw"], "invert": true],
            ]])
        }
        if tags.contains("geosite-cn") {
            direct.append(["clash_mode": "Whitelist", "rule_set": ["geosite-cn"]])
        }
        return [false, true].map { inverse in
            ["type": "logical", "mode": "or", "rules": direct, "invert": inverse,
             "action": "resolve", "server": inverse ? "dns-proxy" : "dns-direct", "strategy": "prefer_ipv4"]
        }
    }

    static var bootstrapResolver: [String: Any] {
        ["server": "dns-direct", "strategy": "prefer_ipv4"]
    }

    /// A missing tunnel DNS address must abort before network settings apply.
    public static func requireTunnelServers(_ servers: [String]) throws -> [String] {
        let nonempty = servers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonempty.isEmpty else {
            throw NSError(domain: "PendingNetDNS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法接管系统 DNS，隧道未启动。请重新连接。"])
        }
        return nonempty
    }
}
