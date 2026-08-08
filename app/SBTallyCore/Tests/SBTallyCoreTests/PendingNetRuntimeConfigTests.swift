import XCTest
@testable import SBTallyCore

final class PendingNetRuntimeConfigTests: XCTestCase {
    func testProxyOnlyBaseOwnsLocalPolicy() throws {
        let data = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "mixed")
        XCTAssertEqual(inbound["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbound["listen_port"] as? Int, 2080)
        XCTAssertNil(root["dns"], "DNS policy must not come from the pairing document")

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["external_controller"] as? String, "127.0.0.1:29090")
        XCTAssertEqual(clash["default_mode"] as? String, "Global")
        XCTAssertEqual(clash["secret"] as? String, "test-secret")
    }

    func testProxyOnlyBasePassesInstalledSingBoxCheck() throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("sing-box is not installed") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-config-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
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

    /// 全局以外的模式必须被 route 规则声明，否则 sing-box 会照收 API 请求
    /// （204）却根本不切 —— 界面上显示白名单，引擎其实还在全局。
    func testListModesAppearOnlyWithRuleSets() throws {
        let without = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        XCTAssertFalse(PendingNetProxyOnlyConfig.declaresListModes(without))

        let with = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db",
            ruleSetDirectory: "/tmp/pendingnet-rule-sets"
        )
        XCTAssertTrue(PendingNetProxyOnlyConfig.declaresListModes(with))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: with) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let modes = Set((route["rules"] as? [[String: Any]] ?? []).compactMap {
            $0["clash_mode"] as? String
        })
        XCTAssertEqual(modes, ["Direct", "Global", "Whitelist", "Blacklist"])
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, PendingNetProxyOnlyConfig.ruleSetFiles.count)
        for set in ruleSets {
            XCTAssertEqual(set["type"] as? String, "local")
            XCTAssertTrue((set["path"] as? String ?? "")
                .hasPrefix("/tmp/pendingnet-rule-sets/"))
        }
    }

    /// macOS 的两个列表档位必须各自按真正用到的规则集启用：GFW 名单缺失
    /// 不得连坐白名单，反过来国内名单缺失也不得把黑名单一起藏掉。
    func testEachListModeIsDeclaredIndependentlyFromAvailableRuleSets() throws {
        let directory = "/tmp/pendingnet-rule-sets"
        let whitelist = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db",
            ruleSetDirectory: directory,
            availableRuleSetTags: ["geoip-cn", "geosite-cn"]
        )
        XCTAssertEqual(PendingNetProxyOnlyConfig.declaredListModes(whitelist), [.whitelist])
        let whitelistRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: whitelist) as? [String: Any]
        )
        let whitelistRoute = try XCTUnwrap(whitelistRoot["route"] as? [String: Any])
        XCTAssertEqual(
            Set((whitelistRoute["rule_set"] as? [[String: Any]] ?? []).compactMap {
                $0["tag"] as? String
            }),
            ["geoip-cn", "geosite-cn"]
        )

        let blacklist = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db",
            ruleSetDirectory: directory,
            availableRuleSetTags: ["geosite-gfw"]
        )
        XCTAssertEqual(PendingNetProxyOnlyConfig.declaredListModes(blacklist), [.blacklist])
        let blacklistRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: blacklist) as? [String: Any]
        )
        let blacklistRoute = try XCTUnwrap(blacklistRoot["route"] as? [String: Any])
        XCTAssertEqual(
            Set((blacklistRoute["rule_set"] as? [[String: Any]] ?? []).compactMap {
                $0["tag"] as? String
            }),
            ["geosite-gfw"]
        )
    }

    /// 名单下载完成后要能就地补上，不能逼用户重新配对 VPS。
    func testApplyingRouteRulesKeepsMergedOutbounds() throws {
        let base = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let selectorTag = PendingNetRuntimeServer.selectorTag(forServerID: "pns_test")
        let merged = try PendingNetLocalConfigComposer.merge(
            baseConfig: base,
            runtimeServer: PendingNetRuntimeServer(
                serverID: "pns_test",
                name: "VPS",
                selectorTag: selectorTag,
                proxyOutbounds: Data("""
                [{"type":"hysteria2","tag":"\(selectorTag)-hy2",\
                "server":"1.2.3.4","server_port":443,"password":"p"}]
                """.utf8)
            )
        )
        let upgraded = try PendingNetProxyOnlyConfig.applyingRouteRules(
            to: merged,
            ruleSetDirectory: "/tmp/pendingnet-rule-sets"
        )
        XCTAssertTrue(PendingNetProxyOnlyConfig.declaresListModes(upgraded))
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        let tags = { (root: [String: Any]) in
            (root["outbounds"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
        }
        XCTAssertEqual(tags(before), tags(after))
    }

    /// 在设置里改端口、开局域网访问都不该让用户重新配对 VPS，也不该撞上控制端口。
    func testApplyingLocalInboundKeepsEverythingElse() throws {
        let base = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let moved = try PendingNetProxyOnlyConfig.applyingLocalInbound(
            to: base,
            port: 3128,
            listenAddress: PendingNetProxyOnlyConfig.anyListen
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: moved) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["listen_port"] as? Int, 3128)
        XCTAssertEqual(inbound["listen"] as? String, "0.0.0.0")
        let clash = try XCTUnwrap((root["experimental"] as? [String: Any])?["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["secret"] as? String, "test-secret")

        let loopback = PendingNetProxyOnlyConfig.loopbackListen
        XCTAssertThrowsError(try PendingNetProxyOnlyConfig.applyingLocalInbound(
            to: base, port: 80, listenAddress: loopback))
        XCTAssertThrowsError(try PendingNetProxyOnlyConfig.applyingLocalInbound(
            to: base, port: 29090, listenAddress: loopback))
        XCTAssertThrowsError(try PendingNetProxyOnlyConfig.applyingLocalInbound(
            to: base, port: 3128, listenAddress: "8.8.8.8"))
    }

    func testProxyOnlyBaseSupportsAnIsolatedListenPort() throws {
        let data = try PendingNetProxyOnlyConfig.make(
            controlSecret: "test-secret",
            cachePath: "/tmp/pendingnet-cache.db",
            listenPort: 2081
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["listen_port"] as? Int, 2081)
    }

    func testGeneratesPolicyFreeSingBoxOutbounds() throws {
        let data = Data("""
        {
          "version":1,"server_id":"pns_test","updated_at":"2026-07-31T12:00:00Z",
          "protocols":[
            {
              "id":"reality","type":"vless-reality","display_name":"Reality",
              "vless_reality":{
                "server":"203.0.113.10","server_port":443,"uuid":"uuid",
                "flow":"xtls-rprx-vision","server_name":"example.com",
                "public_key":"public-key","short_id":"abcdef12"
              }
            },
            {
              "id":"hy2","type":"hysteria2","display_name":"Hysteria2",
              "hysteria2":{
                "server":"203.0.113.10","server_port":8443,"password":"secret",
                "obfs_type":"salamander","obfs_password":"obfs","server_name":"203.0.113.10",
                "certificate_public_key_sha256":"base64-pin="
              }
            }
          ]
        }
        """.utf8)
        let profile = try JSONDecoder().decode(PendingNetNodeProfile.self, from: data)
        let generated = try profile.singBoxProxyOutbounds(tagPrefix: "vps")
        let outbounds = try XCTUnwrap(
            JSONSerialization.jsonObject(with: generated) as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 2)
        XCTAssertEqual(outbounds[0]["type"] as? String, "vless")
        XCTAssertEqual(outbounds[1]["type"] as? String, "hysteria2")

        let realityTLS = try XCTUnwrap(outbounds[0]["tls"] as? [String: Any])
        XCTAssertNotNil(realityTLS["reality"])
        let hy2TLS = try XCTUnwrap(outbounds[1]["tls"] as? [String: Any])
        XCTAssertEqual(hy2TLS["certificate_public_key_sha256"] as? [String], ["base64-pin="])

        let text = String(decoding: generated, as: UTF8.self)
        for forbidden in ["route", "rule_set", "inbounds", "tun"] {
            XCTAssertFalse(text.contains(forbidden), "generated client policy field \(forbidden)")
        }
    }

    func testMergesManagedVPSWithoutChangingClientPolicy() throws {
        let base = Data(#"""
        {
          "dns":{"final":"dns-proxy"},
          "inbounds":[{"type":"tun","tag":"tun-in"}],
          "route":{"final":"proxy","rules":[{"clash_mode":"Global","outbound":"proxy"}]},
          "outbounds":[
            {"type":"vless","tag":"pendingnet-abcdef-old"},
            {"type":"selector","tag":"pendingnet-abcdef","outbounds":["pendingnet-abcdef-old"]},
            {"type":"selector","tag":"legacy","outbounds":["legacy-reality"]},
            {"type":"selector","tag":"proxy","outbounds":["legacy","pendingnet-abcdef"]},
            {"type":"direct","tag":"direct"}
          ]
        }
        """#.utf8)
        let runtime = PendingNetRuntimeServer(
            serverID: "pns_test",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data(#"""
            [
              {"type":"vless","tag":"pendingnet-abcdef-reality","server":"203.0.113.10"},
              {"type":"hysteria2","tag":"pendingnet-abcdef-hy2","server":"203.0.113.10"}
            ]
            """#.utf8)
        )

        let merged = try PendingNetLocalConfigComposer.merge(baseConfig: base, runtimeServer: runtime)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual((root["dns"] as? [String: String])?["final"], "dns-proxy")
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "proxy")
        XCTAssertEqual((root["inbounds"] as? [[String: Any]])?.count, 1)

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        XCTAssertFalse(tags.contains("pendingnet-abcdef-old"))
        XCTAssertTrue(tags.contains("pendingnet-abcdef-reality"))
        XCTAssertTrue(tags.contains("pendingnet-abcdef-hy2"))
        XCTAssertTrue(tags.contains("pendingnet-abcdef-mix"))
        XCTAssertTrue(tags.contains("legacy"))
        XCTAssertTrue(tags.contains("direct"))

        let proxy = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "proxy" })
        XCTAssertEqual(proxy["outbounds"] as? [String], ["pendingnet-abcdef", "legacy"])

        let mergedAgain = try PendingNetLocalConfigComposer.merge(
            baseConfig: merged, runtimeServer: runtime)
        let secondRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedAgain) as? [String: Any])
        let secondOutbounds = try XCTUnwrap(secondRoot["outbounds"] as? [[String: Any]])
        XCTAssertEqual(
            secondOutbounds.filter { (($0["tag"] as? String) ?? "").hasPrefix("pendingnet-abcdef") }.count,
            4
        )
    }

    func testMergeRequiresProxySelector() throws {
        let runtime = PendingNetRuntimeServer(
            serverID: "pns_test",
            name: "Test VPS",
            selectorTag: "pendingnet-abcdef",
            proxyOutbounds: Data(#"[{"type":"vless","tag":"pendingnet-abcdef-reality"}]"#.utf8)
        )
        XCTAssertThrowsError(try PendingNetLocalConfigComposer.merge(
            baseConfig: Data(#"{"outbounds":[]}"#.utf8),
            runtimeServer: runtime
        )) { error in
            XCTAssertEqual(error as? PendingNetRuntimeConfigError, .missingProxySelector)
        }
    }
}
