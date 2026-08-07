import XCTest
@testable import SBTallyCore

final class PendingNetTunnelConfigTests: XCTestCase {
    /// 构造一份双协议节点资料，字段与 PendingNetNodeProfile 的 CodingKeys 对齐。
    static func sampleProfile() -> PendingNetNodeProfile {
        PendingNetNodeProfile(
            version: 3,
            serverID: "pn_test_server",
            updatedAt: "2026-08-07T00:00:00Z",
            protocols: [
                .init(
                    id: "reality",
                    type: "vless-reality",
                    displayName: "Reality",
                    vlessReality: .init(
                        server: "203.0.113.10",
                        serverPort: 443,
                        uuid: "11111111-2222-3333-4444-555555555555",
                        flow: "xtls-rprx-vision",
                        serverName: "www.cloudflare.com",
                        publicKey: "JHjxqELXV16enBs4C429HrFtjC9s3jckg3Egv480n8k",
                        shortID: "0123abcd"
                    ),
                    hysteria2: nil
                ),
                .init(
                    id: "hy2",
                    type: "hysteria2",
                    displayName: "Hysteria2",
                    vlessReality: nil,
                    hysteria2: .init(
                        server: "203.0.113.10",
                        serverPort: 443,
                        password: "hy2-password",
                        obfsType: "salamander",
                        obfsPassword: "obfs-password",
                        serverName: "bing.com",
                        certificatePublicKeySHA256: "3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                    )
                ),
            ]
        )
    }

    static func sampleRuntimeServer() throws -> PendingNetRuntimeServer {
        try sampleProfile().runtimeServer(name: "Test VPS")
    }

    func testGlobalModeBuildsTunInboundAndSelector() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        let tun = try XCTUnwrap(inbounds.first)
        XCTAssertEqual(tun["type"] as? String, "tun")
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["mtu"] as? Int, 9000)
        XCTAssertNotNil(tun["address"] as? [String])

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        XCTAssertTrue(tags.contains(server.selectorTag))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-mix"))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-reality"))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-hy2"))
        XCTAssertTrue(tags.contains("direct"))
        XCTAssertFalse(
            outbounds.contains { ($0["type"] as? String) == "block" },
            "block outbound 在 sing-box 1.11+ 已废弃，改用 route action reject"
        )

        let selector = try XCTUnwrap(outbounds.first { $0["tag"] as? String == server.selectorTag })
        XCTAssertEqual(selector["type"] as? String, "selector")
        let members = try XCTUnwrap(selector["outbounds"] as? [String])
        XCTAssertEqual(
            members,
            ["\(server.selectorTag)-reality", "\(server.selectorTag)-hy2", "\(server.selectorTag)-mix"]
        )

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, server.selectorTag)
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        XCTAssertNil(route["rule_set"], "全局模式不加载任何规则集")

        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let cache = try XCTUnwrap(experimental["cache_file"] as? [String: Any])
        XCTAssertEqual(cache["path"] as? String, "/tmp/pendingnet-cache.db")
        XCTAssertNil(
            experimental["clash_api"],
            "iOS 用 libbox command server，不需要 clash_api"
        )
    }

    func testServerMaterialCannotInfluenceClientPolicy() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])

        // 服务端资料只能出现在协议 outbound 里，不得污染 inbound/route/dns。
        for outbound in outbounds where (outbound["tag"] as? String)?.hasPrefix(server.selectorTag + "-") == true {
            XCTAssertNil(outbound["inbounds"])
            XCTAssertNil(outbound["route"])
        }
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertNil(tun["server"], "tun inbound 不得携带任何服务端字段")
    }

    func testBypassCNRoutesDomesticTrafficDirect() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .bypassCN,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 2)
        for ruleSet in ruleSets {
            XCTAssertEqual(ruleSet["type"] as? String, "local")
            XCTAssertEqual(ruleSet["format"] as? String, "binary")
            let path = try XCTUnwrap(ruleSet["path"] as? String)
            XCTAssertTrue(path.hasPrefix("/tmp/rs/"))
            XCTAssertTrue(path.hasSuffix(".srs"))
        }
        XCTAssertEqual(
            Set(ruleSets.compactMap { $0["tag"] as? String }),
            Set(PendingNetTunnelConfig.requiredRuleSetNames)
        )

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["ip_is_private"] as? Bool) == true
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geoip-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertEqual(route["final"] as? String, server.selectorTag)

        // .bypassCN 仍然把绝大多数流量送进隧道，域名解析默认走代理侧解析器；
        // 只有命中 geosite-cn 的域名才会被下面的 dns.rules 摘出来走直连。
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-proxy")

        // 国内域名必须用直连解析器，否则分流判断本身要先过一次代理。
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["server"] as? String) == "dns-direct" })
    }

    func testDirectModeKeepsTunnelUpButSendsEverythingDirect() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .direct,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertNil(route["rule_set"], "应急模式不依赖任何规则集文件")
        XCTAssertEqual((root["dns"] as? [String: Any])?["final"] as? String, "dns-direct")

        // .direct 是应急全直连：域名解析也必须走直连解析器，否则解析本身
        // 仍会绕回代理，与"应急模式下不依赖代理"的意图相悖。
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-direct")

        // 隧道仍然建立，selector 仍然在位，方便一键切回。
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertTrue(outbounds.contains { $0["tag"] as? String == server.selectorTag })
        XCTAssertEqual((root["inbounds"] as? [[String: Any]])?.first?["type"] as? String, "tun")
    }

    func testEveryRouteModePassesInstalledSingBoxCheck() throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("sing-box is not installed") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-modes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // sing-box check 会真的解析 local rule_set 文件的内容（即便是
        // type: local + format: binary 也要能反解出一个空规则集），所以占位文件
        // 必须是用 `sing-box rule-set compile` 生成的真实 .srs，不能是空字节。
        // 真实规则内容由 Task 10 下载器落地；此处只验证 schema 与路径拼装。
        for name in PendingNetTunnelConfig.requiredRuleSetNames {
            let sourceJSON = directory.appendingPathComponent("\(name).json")
            try Data(#"{"version":1,"rules":[]}"#.utf8).write(to: sourceJSON)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: binary)
            compile.arguments = [
                "rule-set", "compile", sourceJSON.path,
                "-o", directory.appendingPathComponent("\(name).srs").path,
            ]
            let compileOutput = Pipe()
            compile.standardOutput = compileOutput
            compile.standardError = compileOutput
            try compile.run()
            let compileData = compileOutput.fileHandleForReading.readDataToEndOfFile()
            compile.waitUntilExit()
            XCTAssertEqual(
                compile.terminationStatus, 0,
                "compiling placeholder rule-set \(name): \(String(decoding: compileData, as: UTF8.self))"
            )
        }

        for mode in PendingNetRouteMode.allCases {
            let configURL = directory.appendingPathComponent("config-\(mode.rawValue).json")
            try PendingNetTunnelConfig.make(
                runtimeServer: Self.sampleRuntimeServer(),
                routeMode: mode,
                ruleSetDirectory: directory.path,
                cachePath: directory.appendingPathComponent("cache-\(mode.rawValue).db").path
            ).write(to: configURL)

            let check = Process()
            check.executableURL = URL(fileURLWithPath: binary)
            check.arguments = ["check", "-c", configURL.path]
            let output = Pipe()
            check.standardOutput = output
            check.standardError = output
            try check.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            check.waitUntilExit()
            XCTAssertEqual(
                check.terminationStatus, 0,
                "\(mode.rawValue): \(String(decoding: data, as: UTF8.self))"
            )
        }
    }

    func testDNSNeverUsesLocalTransport() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])

        // 实测根因：local transport 走 cgo darwinLookupSystemDNS，
        // 每个阻塞查询占住一个 OS 线程，266 个查询即撑爆内存。
        XCTAssertFalse(
            servers.contains { ($0["type"] as? String) == "local" },
            "local DNS transport 会造成 goroutine/线程堆积，禁止出现"
        )
        XCTAssertTrue(servers.allSatisfy { ($0["type"] as? String) == "https" })

        let tags = servers.compactMap { $0["tag"] as? String }
        XCTAssertEqual(Set(tags), ["dns-proxy", "dns-direct"])

        // 代理侧 DNS 必须走 selector，直连侧必须走 direct，
        // 否则隧道建立前的 DNS 查询会打进黑洞而不回收。
        let proxyServer = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-proxy" })
        XCTAssertEqual(proxyServer["detour"] as? String, server.selectorTag)
        let directServer = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-direct" })
        XCTAssertEqual(directServer["detour"] as? String, "direct")

        // ipv4_only 把每个域名的查询数从 A+AAAA 两条降到一条。
        XCTAssertEqual(dns["strategy"] as? String, "ipv4_only")
        XCTAssertEqual(dns["disable_cache"] as? Bool, false)
        XCTAssertEqual(dns["independent_cache"] as? Bool, false)
        XCTAssertEqual(dns["final"] as? String, "dns-proxy")
    }

    func testDNSTrafficIsHijackedIntoTheResolver() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertTrue(
            rules.contains {
                ($0["protocol"] as? String) == "dns" && ($0["action"] as? String) == "hijack-dns"
            },
            "未劫持 DNS 会让系统解析器绕过隧道"
        )

        // sing-box 1.12+ 要求显式声明 default_domain_resolver；.global 模式下
        // 必须指到 dns-proxy，否则未来触发这条路径的解析（route resolve
        // action、ICMP-to-domain、WireGuard/Tailscale 端点、SOCKS4）会漏出隧道。
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-proxy")
    }

    func testTunnelConfigPassesInstalledSingBoxCheck() throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("sing-box is not installed") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-tunnel-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try PendingNetTunnelConfig.make(
            runtimeServer: Self.sampleRuntimeServer(),
            routeMode: .global,
            ruleSetDirectory: directory.path,
            cachePath: directory.appendingPathComponent("cache.db").path
        ).write(to: configURL)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: binary)
        check.arguments = ["check", "-c", configURL.path]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Shared managedProxyOutbounds() validator

    /// Both PendingNetTunnelConfig.make and PendingNetLocalConfigComposer.merge
    /// funnel through PendingNetRuntimeServer.managedProxyOutbounds(). These
    /// cases lock down its guards so the two call sites can't drift again.

    func testManagedProxyOutboundsRejectsEmptyOutbounds() throws {
        let server = PendingNetRuntimeServer(
            serverID: "pn_test_server",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data("[]".utf8)
        )
        XCTAssertThrowsError(try server.managedProxyOutbounds()) { error in
            XCTAssertEqual(error as? PendingNetRuntimeConfigError, .invalidLocalConfiguration)
        }
    }

    func testManagedProxyOutboundsRejectsWrongOutboundType() throws {
        let server = PendingNetRuntimeServer(
            serverID: "pn_test_server",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data(#"[{"type":"shadowsocks","tag":"pendingnet-abcdef-reality"}]"#.utf8)
        )
        XCTAssertThrowsError(try server.managedProxyOutbounds()) { error in
            XCTAssertEqual(error as? PendingNetRuntimeConfigError, .invalidLocalConfiguration)
        }
    }

    func testManagedProxyOutboundsRejectsTagMissingSelectorPrefix() throws {
        let server = PendingNetRuntimeServer(
            serverID: "pn_test_server",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data(#"[{"type":"vless","tag":"other-server-reality"}]"#.utf8)
        )
        XCTAssertThrowsError(try server.managedProxyOutbounds()) { error in
            XCTAssertEqual(error as? PendingNetRuntimeConfigError, .invalidLocalConfiguration)
        }
    }

    func testManagedProxyOutboundsRejectsDuplicateTag() throws {
        let server = PendingNetRuntimeServer(
            serverID: "pn_test_server",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data(#"""
            [
              {"type":"vless","tag":"pendingnet-abcdef-reality"},
              {"type":"hysteria2","tag":"pendingnet-abcdef-reality"}
            ]
            """#.utf8)
        )
        XCTAssertThrowsError(try server.managedProxyOutbounds()) { error in
            XCTAssertEqual(error as? PendingNetRuntimeConfigError, .invalidLocalConfiguration)
        }
    }
}

final class PendingNetTunnelPathsTests: XCTestCase {
    func testLayoutIsStableRelativeToContainer() throws {
        let base = URL(fileURLWithPath: "/tmp/group-container")
        XCTAssertEqual(PendingNetTunnelPaths.appGroupID, "group.net.pending.PendingNet")
        XCTAssertEqual(PendingNetTunnelPaths.configURL(in: base).path, "/tmp/group-container/config.json")
        XCTAssertEqual(
            PendingNetTunnelPaths.snapshotURL(in: base).path,
            "/tmp/group-container/start-options.json"
        )
        XCTAssertEqual(PendingNetTunnelPaths.cacheURL(in: base).path, "/tmp/group-container/cache.db")
        XCTAssertEqual(
            PendingNetTunnelPaths.stderrLogURL(in: base).path,
            "/tmp/group-container/stderr.log"
        )
        XCTAssertEqual(
            PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            "/tmp/group-container/rulesets"
        )
    }

    func testPrepareCreatesRuleSetDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try PendingNetTunnelPaths.prepare(base: base)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPrepareIsIdempotent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try PendingNetTunnelPaths.prepare(base: base)
        XCTAssertNoThrow(try PendingNetTunnelPaths.prepare(base: base))
    }
}
