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
                        publicKey: "cHVibGljLWtleS1wbGFjZWhvbGRlcg",
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

    func testUnimplementedRouteModesAreRejectedForNow() throws {
        let server = try Self.sampleRuntimeServer()
        for mode in [PendingNetRouteMode.bypassCN, .direct] {
            XCTAssertThrowsError(
                try PendingNetTunnelConfig.make(
                    runtimeServer: server,
                    routeMode: mode,
                    ruleSetDirectory: "/tmp/pendingnet-rulesets",
                    cachePath: "/tmp/pendingnet-cache.db"
                )
            )
        }
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
