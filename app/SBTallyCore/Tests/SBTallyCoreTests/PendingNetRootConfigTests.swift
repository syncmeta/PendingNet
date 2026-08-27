import XCTest
@testable import SBTallyCore

final class PendingNetRootConfigTests: XCTestCase {
    func testRootVariantsOwnTheSamePolicyAndDifferOnlyByTUN() throws {
        let tun = try PendingNetRootConfig.make(
            enableTUN: true,
            controlSecret: "root-secret",
            cachePath: "/usr/local/etc/sbtally/cache.db"
        )
        let noTun = try PendingNetRootConfig.make(
            enableTUN: false,
            controlSecret: "root-secret",
            cachePath: "/usr/local/etc/sbtally/cache.db"
        )
        let tunRoot = try Self.root(tun)
        let noTunRoot = try Self.root(noTun)

        XCTAssertTrue(Self.hasTUN(tunRoot))
        XCTAssertFalse(Self.hasTUN(noTunRoot))
        for key in ["dns", "outbounds", "route", "experimental"] {
            XCTAssertEqual(
                try JSONSerialization.data(withJSONObject: tunRoot[key] as Any, options: [.sortedKeys]),
                try JSONSerialization.data(withJSONObject: noTunRoot[key] as Any, options: [.sortedKeys])
            )
        }
        let experimental = try XCTUnwrap(tunRoot["experimental"] as? [String: Any])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clash["external_controller"] as? String, "127.0.0.1:9090")
        XCTAssertEqual(clash["secret"] as? String, "root-secret")
    }

    func testPairingOutboundsMergeIntoBothRootVariants() throws {
        let selector = PendingNetRuntimeServer.selectorTag(forServerID: "pns_root_test")
        let runtime = PendingNetRuntimeServer(
            serverID: "pns_root_test",
            name: "Root test",
            selectorTag: selector,
            proxyOutbounds: Data("""
            [{"type":"hysteria2","tag":"\(selector)-hy2",\
              "server":"198.51.100.1","server_port":443,"password":"test"}]
            """.utf8)
        )
        for tun in [true, false] {
            let merged = try PendingNetLocalConfigComposer.merge(
                baseConfig: PendingNetRootConfig.make(
                    enableTUN: tun,
                    controlSecret: "root-secret",
                    cachePath: "/usr/local/etc/sbtally/cache.db"
                ),
                runtimeServer: runtime
            )
            let root = try Self.root(merged)
            let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
            let proxy = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "proxy" })
            XCTAssertEqual((proxy["outbounds"] as? [String])?.first, selector)
            XCTAssertEqual(Self.hasTUN(root), tun)
        }
    }

    func testDomesticDNSUsesExplicitDirectResolver() throws {
        let root = try Self.root(PendingNetRootConfig.make(
            enableTUN: true,
            controlSecret: "root-secret",
            cachePath: "/usr/local/etc/sbtally/cache.db"
        ))
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let direct = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-direct" })
        XCTAssertEqual(direct["type"] as? String, "udp")
        XCTAssertEqual(direct["server"] as? String, "223.5.5.5")
        XCTAssertEqual(direct["server_port"] as? Int, 53)
        XCTAssertEqual(direct["detour"] as? String, "direct")
        XCTAssertFalse(servers.contains { $0["type"] as? String == "local" })

        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.first?["server"] as? String, "dns-direct")
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let routeRules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertFalse(routeRules.contains { $0["server"] as? String == "dns-local" })
        XCTAssertTrue(routeRules.contains { $0["server"] as? String == "dns-direct" })
    }

    func testMigratesOnlyExactLegacyLocalDNSAndKeepsOtherPolicy() throws {
        let legacy = Data(#"""
        {
          "dns": {
            "servers": [
              {"type":"https","tag":"dns-proxy","server":"1.1.1.1"},
              {"type":"local","tag":"dns-local"}
            ],
            "rules": [{"rule_set":["geosite-cn"],"server":"dns-local"}]
          },
          "route": {"rules":[{"action":"resolve","server":"dns-local"}]},
          "outbounds": [{"type":"selector","tag":"kept-vps"}],
          "custom": {"kept":true}
        }
        """#.utf8)
        let migrated = try Self.root(PendingNetRootConfig.migratingLegacyLocalDNS(in: legacy))
        XCTAssertEqual((migrated["custom"] as? [String: Bool])?["kept"], true)
        XCTAssertEqual((migrated["outbounds"] as? [[String: Any]])?.first?["tag"] as? String,
                       "kept-vps")
        let dns = try XCTUnwrap(migrated["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertNotNil(servers.first { $0["tag"] as? String == "dns-direct" })
        XCTAssertNil(servers.first { $0["tag"] as? String == "dns-local" })

        let customized = Data(#"{"dns":{"servers":[{"type":"local","tag":"dns-local","prefer_go":true}]}}"#.utf8)
        XCTAssertEqual(try PendingNetRootConfig.migratingLegacyLocalDNS(in: customized), customized)
    }

    func testVariantPreservesExistingPolicy() throws {
        let source = Data(#"{"inbounds":[{"type":"tun","tag":"old"},{"type":"mixed","listen_port":3128}],"outbounds":[{"type":"direct","tag":"custom"}],"custom":{"kept":true}}"#.utf8)
        let noTun = try Self.root(PendingNetRootConfig.variant(from: source, enableTUN: false))
        XCTAssertFalse(Self.hasTUN(noTun))
        XCTAssertEqual((noTun["custom"] as? [String: Bool])?["kept"], true)
        let outbounds = try XCTUnwrap(noTun["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.first?["tag"] as? String, "custom")

        let tun = try Self.root(PendingNetRootConfig.variant(
            from: try JSONSerialization.data(withJSONObject: noTun), enableTUN: true))
        XCTAssertTrue(Self.hasTUN(tun))
        XCTAssertEqual((tun["inbounds"] as? [[String: Any]])?.filter {
            $0["type"] as? String == "tun"
        }.count, 1)
    }

    private static func root(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func hasTUN(_ root: [String: Any]) -> Bool {
        (root["inbounds"] as? [[String: Any]] ?? []).contains {
            $0["type"] as? String == "tun"
        }
    }
}
