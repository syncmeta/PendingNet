import Foundation

public struct PendingNetClientExportOptions: Equatable, Sendable {
    public enum Platform: String, CaseIterable, Sendable { case android, windows }
    public enum Mode: String, CaseIterable, Sendable { case port, sysproxy, tun }
    public var platform: Platform = .android
    public var mode: Mode = .tun
    public var port: Int = 2080
    public var allowsLAN = false
    public var protocolID: String = "mix"
    public init() {}
}

public enum PendingNetClientExport {
    public static func make(profile: PendingNetNodeProfile, options: PendingNetClientExportOptions) throws -> Data {
        guard (1...65535).contains(options.port) else { throw PendingNetRuntimeConfigError.invalidLocalConfiguration }
        let runtime = try profile.runtimeServer(name: "export")
        let (nodes, tags) = try runtime.managedProxyOutbounds()
        var outbounds = nodes
        let final: String
        if options.protocolID == "mix" {
            final = "proxy"
            outbounds.append(["type": "urltest", "tag": final, "outbounds": tags])
        } else {
            final = runtime.selectorTag + "-" + options.protocolID
            guard tags.contains(final) else { throw PendingNetRuntimeConfigError.invalidLocalConfiguration }
            outbounds = nodes.filter { $0["tag"] as? String == final }
        }
        var mixed: [String: Any] = ["type": "mixed", "tag": "mixed-in",
            "listen": options.allowsLAN ? "0.0.0.0" : "127.0.0.1", "listen_port": options.port]
        if options.mode == .sysproxy { mixed["set_system_proxy"] = true }
        var inbounds: [[String: Any]] = [mixed]
        var route: [String: Any] = ["final": final, "auto_detect_interface": true, "default_domain_resolver": PendingNetDNSPolicy.bootstrapResolver]
        if options.mode == .tun {
            var tun: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true]
            if options.platform == .windows { tun["strict_route"] = true }
            inbounds.insert(tun, at: 0)
            route["rules"] = [["protocol": "dns", "action": "hijack-dns"]]
        }
        var rules = route["rules"] as? [[String: Any]] ?? []
        rules.insert(["action": "sniff"], at: 0)
        rules.append(["action": "resolve", "server": "dns-proxy", "strategy": "prefer_ipv4"])
        route["rules"] = rules
        let config: [String: Any] = ["log": ["level": "warn"], "inbounds": inbounds, "outbounds": outbounds,
            "route": route, "dns": ["servers": PendingNetDNSPolicy.servers(proxy: final), "final": "dns-proxy", "strategy": "prefer_ipv4"]]

        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }
}
