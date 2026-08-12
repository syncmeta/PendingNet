import XCTest
@testable import SBTallyCore

final class PendingNetClashControlTests: XCTestCase {
    private func config(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testReadsEndpointFromConfig() throws {
        let data = config([
            "experimental": ["clash_api": [
                "external_controller": "127.0.0.1:9095",
                "secret": "s3cret",
            ]],
        ])
        let endpoint = try XCTUnwrap(PendingNetClashEndpoint(configData: data))
        XCTAssertEqual(endpoint.controller, "127.0.0.1:9095")
        XCTAssertEqual(endpoint.secret, "s3cret")
        XCTAssertEqual(endpoint.url(path: "configs")?.absoluteString,
                       "http://127.0.0.1:9095/configs")
    }

    func testMissingSecretIsEmptyRatherThanFailure() throws {
        let data = config(["experimental": ["clash_api": ["external_controller": "localhost:9090"]]])
        let endpoint = try XCTUnwrap(PendingNetClashEndpoint(configData: data))
        XCTAssertEqual(endpoint.secret, "")
    }

    func testConfigWithoutClashAPIHasNoEndpoint() {
        XCTAssertNil(PendingNetClashEndpoint(configData: config(["experimental": [:]])))
        XCTAssertNil(PendingNetClashEndpoint(configData: config([:])))
        XCTAssertNil(PendingNetClashEndpoint(configData: Data("not json".utf8)))
    }

    /// 控制口能改整台机器的路由，请求还带着 secret —— 配置写成对外地址时，
    /// 什么都不发才是对的。
    func testNonLoopbackControllerYieldsNoURL() {
        for controller in ["0.0.0.0:9090", "10.0.0.5:9090", "evil.example.com:9090",
                           "user@evil.example.com:9090"] {
            let endpoint = PendingNetClashEndpoint(controller: controller, secret: "")
            XCTAssertNil(endpoint.url(path: "configs"), controller)
        }
    }

    func testDeclaredModesReadRouteRules() {
        // 和 internal/sbconfig/generate.go 生成的那份形状一致。
        let data = config([
            "route": ["rules": [
                ["action": "sniff"],
                ["ip_is_private": true, "outbound": "direct"],
                ["clash_mode": "Global", "outbound": "proxy"],
                ["clash_mode": "Blacklist", "rule_set": "geosite-gfw", "outbound": "proxy"],
                ["clash_mode": "Blacklist", "outbound": "direct"],
                ["clash_mode": "Whitelist", "rule_set": ["geoip-cn"], "outbound": "direct"],
            ]],
        ])
        XCTAssertEqual(PendingNetClashControl.declaredModes(in: data),
                       [.global, .blacklist, .whitelist])
    }

    func testDeclaredModesOfAConfigWithoutRouteRules() {
        XCTAssertEqual(PendingNetClashControl.declaredModes(in: config([:])), [])
        XCTAssertEqual(
            PendingNetClashControl.declaredModes(in: config(["route": ["rules": [["action": "sniff"]]]])),
            []
        )
    }

    func testClashNamesRoundTripCaseInsensitively() {
        XCTAssertEqual(PendingNetRouteMode.global.clashName, "Global")
        XCTAssertEqual(PendingNetRouteMode.whitelist.clashName, "Whitelist")
        XCTAssertEqual(PendingNetRouteMode.blacklist.clashName, "Blacklist")
        for mode in PendingNetRouteMode.allCases {
            XCTAssertEqual(PendingNetRouteMode.clashNamed(mode.clashName), mode)
            XCTAssertEqual(PendingNetRouteMode.clashNamed(mode.clashName.lowercased()), mode)
        }
        XCTAssertNil(PendingNetRouteMode.clashNamed("Direct"))
        XCTAssertNil(PendingNetRouteMode.clashNamed(""))
    }
}
