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
