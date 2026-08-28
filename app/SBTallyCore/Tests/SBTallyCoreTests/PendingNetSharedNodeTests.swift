import XCTest
@testable import SBTallyCore

final class PendingNetSharedNodeTests: XCTestCase {
    func testDecodesVLESSRealityShareLink() throws {
        let node = try PendingNetSharedNode.decode(link:
            "vless://abc-123@203.0.113.8:443?security=reality&sni=www.example.com&pbk=public-key&sid=01&flow=xtls-rprx-vision#Tokyo"
        )
        XCTAssertEqual(node.record.name, "Tokyo")
        XCTAssertEqual(node.record.address, "203.0.113.8")
        XCTAssertTrue(node.record.isSharedNode)
        XCTAssertEqual(node.record.proxyTCPPort, 443)
        XCTAssertEqual(node.profile.protocols.first?.vlessReality?.publicKey, "public-key")
        XCTAssertNoThrow(try node.runtimeServer())
    }

    func testDecodesHysteria2AndHy2Aliases() throws {
        for scheme in ["hysteria2", "hy2"] {
            let node = try PendingNetSharedNode.decode(link:
                "\(scheme)://secret@hy.example.com:8443?sni=hy.example.com&obfs=salamander&obfs-password=mask#HK"
            )
            XCTAssertEqual(node.profile.protocols.first?.hysteria2?.password, "secret")
            XCTAssertEqual(node.profile.protocols.first?.hysteria2?.serverPort, 8443)
            XCTAssertNoThrow(try node.runtimeServer())
        }
    }

    func testBatchImportUsesOneNodePerLineAndIgnoresBlankLines() throws {
        let text = """
        vless://u1@one.example.com:443?security=reality&sni=one.example.com&pbk=k1#One

        hy2://p2@two.example.com:443?sni=two.example.com#Two
        """
        let items = try PendingNetTextImport.decode(text)
        XCTAssertEqual(items.count, 2)
    }

    func testBatchErrorNamesTheBadLine() {
        let text = """
        vless://u1@one.example.com:443?security=reality&sni=one.example.com&pbk=k1
        not-a-link
        """
        XCTAssertThrowsError(try PendingNetTextImport.decode(text)) { error in
            XCTAssertEqual(error as? PendingNetTextImportError, .unsupportedLink(line: 2))
        }
    }
}
