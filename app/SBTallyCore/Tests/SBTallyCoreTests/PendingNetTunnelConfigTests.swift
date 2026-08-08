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

    func testWhitelistRoutesDomesticTrafficDirect() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .whitelist,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        for ruleSet in ruleSets {
            XCTAssertEqual(ruleSet["type"] as? String, "local")
            XCTAssertEqual(ruleSet["format"] as? String, "binary")
            let path = try XCTUnwrap(ruleSet["path"] as? String)
            XCTAssertTrue(path.hasPrefix("/tmp/rs/"))
            XCTAssertTrue(path.hasSuffix(".srs"))
        }
        // 只声明这一档真正引用到的规则集：多余的 rule_set 会被内核照单加载，
        // 白名单没有理由为黑名单的 GFW 名单付内存。
        XCTAssertEqual(
            Set(ruleSets.compactMap { $0["tag"] as? String }),
            ["geoip-cn", "geosite-cn"]
        )

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["ip_is_private"] as? Bool) == true
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geoip-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertEqual(route["final"] as? String, server.selectorTag)

        // 白名单仍然把绝大多数流量送进隧道，域名解析默认走代理侧解析器；
        // 只有命中 geosite-cn 的域名才会被下面的 dns.rules 摘出来走直连。
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-proxy")

        // 国内域名必须用直连解析器，否则分流判断本身要先过一次代理。
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["server"] as? String) == "dns-direct" })
    }

    /// 黑名单是白名单的镜像：兜底直连，只有 GFW 名单里的域名走代理。语义
    /// 与 macOS 的 `clash_mode: Blacklist`（PendingNetProxyOnlyConfig）一致，
    /// 用的也是同一个 geosite-gfw 名单。
    func testBlacklistOnlyProxiesBlockedDomains() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .blacklist,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        XCTAssertEqual(route["final"] as? String, "direct", "黑名单的兜底是直连")

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(Set(ruleSets.compactMap { $0["tag"] as? String }), ["geosite-gfw"])
        XCTAssertEqual(
            ruleSets.first?["path"] as? String,
            "/tmp/rs/geosite-gfw.srs"
        )

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geosite-gfw"]
            && ($0["outbound"] as? String) == server.selectorTag })
        XCTAssertTrue(rules.contains { ($0["ip_is_private"] as? Bool) == true
            && ($0["outbound"] as? String) == "direct" })

        // 绝大多数流量直连，解析默认也走直连侧；被墙的域名单独交给代理侧
        // 解析器，否则拿到的是被污染的结果。
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-direct")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["final"] as? String, "dns-direct")
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { ($0["rule_set"] as? [String]) == ["geosite-gfw"]
            && ($0["server"] as? String) == "dns-proxy" })

        // 隧道仍然建立，selector 仍然在位。
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertTrue(outbounds.contains { $0["tag"] as? String == server.selectorTag })
        XCTAssertEqual((root["inbounds"] as? [[String: Any]])?.first?["type"] as? String, "tun")
    }

    /// 档位改名不能让老用户的设置读成 nil 而被打回默认值。
    func testStoredRouteModeMigratesLegacyRawValues() {
        XCTAssertEqual(PendingNetRouteMode.stored(rawValue: "bypassCN"), .whitelist)
        XCTAssertEqual(PendingNetRouteMode.stored(rawValue: "direct"), .global)
        for mode in PendingNetRouteMode.allCases {
            XCTAssertEqual(PendingNetRouteMode.stored(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(PendingNetRouteMode.stored(rawValue: "nonsense"))
    }

    /// 两端的档位必须是同一套三档，多一档少一档都会让用户以为 iOS 和 macOS
    /// 不是一个东西——这正是这次统一要消除的困惑。
    func testRouteModesMatchTheMacOSClashModes() {
        XCTAssertEqual(
            PendingNetRouteMode.allCases.map(\.rawValue),
            ["global", "whitelist", "blacklist"]
        )
    }

    /// 就绪判断必须按档位收窄。加进名单的 geosite-gfw 只有黑名单用得到，
    /// 它下不来（`raw.githubusercontent.com` 在墙内本来就够呛）不能把老用户
    /// 一直在用的白名单也一起挡掉——那恰恰是他最需要开代理的时候。
    func testWhitelistIsReadyWithoutTheBlacklistRuleSet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ name: String) throws {
            try Data(PendingNetTunnelConfig.ruleSetMagicBytes + [0x03, 0x00])
                .write(to: directory.appendingPathComponent("\(name).srs"))
        }

        // 全局什么都不需要，空目录就该是就绪的。
        XCTAssertTrue(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .global, directory: directory.path)
        )
        XCTAssertFalse(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .whitelist, directory: directory.path)
        )

        // 老用户磁盘上的样子：只有白名单那两份，没有 geosite-gfw。
        try write("geoip-cn")
        try write("geosite-cn")
        XCTAssertTrue(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .whitelist, directory: directory.path),
            "白名单不该因为它根本不引用的 geosite-gfw 缺失而被判为未就绪"
        )
        XCTAssertFalse(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .blacklist, directory: directory.path)
        )

        try write("geosite-gfw")
        XCTAssertTrue(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .blacklist, directory: directory.path)
        )
    }

    /// 反过来也一样：黑名单只吃 geosite-gfw，国内名单缺失不该挡住它。
    func testBlacklistIsReadyWithoutTheDomesticRuleSets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(PendingNetTunnelConfig.ruleSetMagicBytes + [0x03, 0x00])
            .write(to: directory.appendingPathComponent("geosite-gfw.srs"))
        XCTAssertTrue(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .blacklist, directory: directory.path)
        )
        XCTAssertFalse(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .whitelist, directory: directory.path)
        )
    }

    /// 落地的是被中间设备换掉的 HTML 而不是 `.srs` 时，那一档必须判为未就绪
    /// 并重下——「文件在」不等于「能用」。
    func testRuleSetPresenceRejectsPoisonedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(PendingNetTunnelConfig.ruleSetMagicBytes + [0x03, 0x00])
            .write(to: directory.appendingPathComponent("geoip-cn.srs"))
        try Data("<!DOCTYPE html><html><body>blocked</body></html>".utf8)
            .write(to: directory.appendingPathComponent("geosite-cn.srs"))
        XCTAssertFalse(
            PendingNetTunnelConfig.ruleSetsPresent(mode: .whitelist, directory: directory.path)
        )
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

    // MARK: - Rule-set manifest and .srs validation

    /// 名字与下载地址必须来自同一条记录。两处各写各的是运行时才暴露的错误
    /// （`rule-set not found`），而且只在真机上看得见。
    func testRuleSetNamesComeFromTheSingleManifest() {
        XCTAssertEqual(
            PendingNetTunnelConfig.requiredRuleSetNames,
            PendingNetTunnelConfig.requiredRuleSets.map(\.name)
        )
        XCTAssertEqual(
            PendingNetTunnelConfig.requiredRuleSetNames,
            ["geoip-cn", "geosite-cn", "geosite-gfw"]
        )
        // 名单必须覆盖三档配置真正引用到的每一个 tag，否则表现是 sing-box
        // 启动时报 `rule-set not found`，而且只在真机上看得见。
        for mode in PendingNetRouteMode.allCases {
            for tag in PendingNetTunnelConfig.ruleSetTags(mode: mode) {
                XCTAssertTrue(
                    PendingNetTunnelConfig.requiredRuleSetNames.contains(tag),
                    "\(mode.rawValue) 引用了不在下载名单里的规则集：\(tag)"
                )
            }
        }
        // 落盘文件名一律是 `<name>.srs`，不跟着 URL 末段走——上游的
        // geosite-gfw 就叫 gfw.srs。这里只要求来源确实是个 .srs。
        for source in PendingNetTunnelConfig.requiredRuleSets {
            XCTAssertTrue(
                source.url.lastPathComponent.hasSuffix(".srs"),
                "下载地址不像规则集：\(source.name) ← \(source.url)"
            )
        }
        XCTAssertEqual(
            Set(PendingNetTunnelConfig.requiredRuleSetNames).count,
            PendingNetTunnelConfig.requiredRuleSetNames.count,
            "规则集名字重复会让后下载的那份盖掉前一份"
        )
    }

    /// 只按「非空」判断会放过一个 200 + HTML 的门户页——`raw.githubusercontent.com`
    /// 在大陆网络下不可达，这是很现实的结果。必须认魔数。
    func testRuleSetValidationRejectsNonSRSContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-srs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let html = directory.appendingPathComponent("portal.srs")
        try Data("<!DOCTYPE html><html><body>blocked</body></html>".utf8).write(to: html)
        XCTAssertFalse(PendingNetTunnelConfig.looksLikeRuleSet(at: html.path))

        let empty = directory.appendingPathComponent("empty.srs")
        try Data().write(to: empty)
        XCTAssertFalse(PendingNetTunnelConfig.looksLikeRuleSet(at: empty.path))

        let truncated = directory.appendingPathComponent("truncated.srs")
        try Data([0x53, 0x52]).write(to: truncated)
        XCTAssertFalse(PendingNetTunnelConfig.looksLikeRuleSet(at: truncated.path))

        XCTAssertFalse(
            PendingNetTunnelConfig.looksLikeRuleSet(
                at: directory.appendingPathComponent("missing.srs").path
            )
        )

        let good = directory.appendingPathComponent("good.srs")
        try Data([0x53, 0x52, 0x53, 0x03, 0x00]).write(to: good)
        XCTAssertTrue(PendingNetTunnelConfig.looksLikeRuleSet(at: good.path))
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
        XCTAssertEqual(PendingNetTunnelPaths.appGroupID, "group.com.pendingname.pendingnet")
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
        // 崩溃栈必须与 stderr.log 分开：LibboxRedirectStderr 内部是 os.Create，
        // 指向同一个文件会把扩展自己的诊断日志截断掉。
        XCTAssertEqual(
            PendingNetTunnelPaths.crashLogURL(in: base).path,
            "/tmp/group-container/go-crash.log"
        )
        XCTAssertNotEqual(
            PendingNetTunnelPaths.crashLogURL(in: base),
            PendingNetTunnelPaths.stderrLogURL(in: base)
        )
        XCTAssertEqual(
            PendingNetTunnelPaths.lastErrorURL(in: base).path,
            "/tmp/group-container/last-error.txt"
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
