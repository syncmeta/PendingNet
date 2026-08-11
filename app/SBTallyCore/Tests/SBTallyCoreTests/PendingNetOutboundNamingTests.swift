import XCTest
@testable import SBTallyCore

final class PendingNetOutboundNamingTests: XCTestCase {
    private let selector = "pendingnet-a1b2c3"

    func testThreeOptionsAreNamedTheSameOnBothPlatforms() {
        // 两端都只从这一个函数取名字，所以这三条就是界面上那三个选项。
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "\(selector)-reality", selectorTag: selector),
            "Reality"
        )
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "\(selector)-hy2", selectorTag: selector),
            "Hysteria2"
        )
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "\(selector)-mix", selectorTag: selector),
            "混合"
        )
    }

    func testSelectorOrderGivesRealityHysteria2ThenMix() throws {
        // 成员顺序由内核给，界面不重排——这里钉住内核给出的就是这个顺序。
        let profile = PendingNetNodeProfile(
            version: 1,
            serverID: "s1",
            updatedAt: "now",
            protocols: [
                .init(
                    id: "reality",
                    type: "vless-reality",
                    displayName: "Reality",
                    vlessReality: .init(
                        server: "203.0.113.10",
                        serverPort: 443,
                        uuid: "u",
                        flow: "xtls-rprx-vision",
                        serverName: "www.cloudflare.com",
                        publicKey: "k",
                        shortID: "01"
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
                        password: "p",
                        obfsType: "salamander",
                        obfsPassword: "o",
                        serverName: "vps",
                        certificatePublicKeySHA256: "bb"
                    )
                ),
            ]
        )
        let runtime = try profile.runtimeServer(name: "VPS")
        let base = """
        {"outbounds":[{"type":"selector","tag":"proxy","outbounds":["direct"]},
        {"type":"direct","tag":"direct"}]}
        """
        let merged = try PendingNetLocalConfigComposer.merge(
            baseConfig: Data(base.utf8),
            runtimeServer: runtime
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let selectorMembers = try XCTUnwrap(
            outbounds.first { ($0["tag"] as? String) == runtime.selectorTag }?["outbounds"] as? [String]
        )
        XCTAssertEqual(
            selectorMembers.map {
                PendingNetOutboundNaming.title(forMemberTag: $0, selectorTag: runtime.selectorTag)
            },
            ["Reality", "Hysteria2", "混合"]
        )
    }

    func testUnknownProtocolFallsBackToItsOwnID() {
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "\(selector)-shadowsocks", selectorTag: selector),
            "shadowsocks"
        )
    }

    func testTagWithoutMatchingSelectorIsLeftAlone() {
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "direct", selectorTag: selector),
            "direct"
        )
    }

    func testWorksWithoutKnowingTheSelectorTag() {
        // macOS 那边偶尔只拿得到成员 tag 本身。
        XCTAssertEqual(
            PendingNetOutboundNaming.title(forMemberTag: "mix", selectorTag: nil),
            "混合"
        )
    }
}
