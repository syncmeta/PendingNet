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

    func testImportErrorsKeepFormattedLineNumbers() {
        XCTAssertFalse(PendingNetTextImportError.empty.localizedDescription.isEmpty)
        for (error, line) in [
            (PendingNetTextImportError.unsupportedLink(line: 2), "2"),
            (.managementLink(line: 3), "3"),
        ] {
            XCTAssertFalse(error.localizedDescription.contains("%lld"))
            XCTAssertTrue(error.localizedDescription.contains(line))
        }
    }
}

extension PendingNetSharedNodeTests {
    func testRealityLinkAndPairedProfileProduceIdenticalProtocolParameters() throws {
        let original = try PendingNetSharedNode.decode(link:
            "vless://11111111-1111-4111-8111-111111111111@203.0.113.8:443?security=reality&type=tcp&encryption=none&sni=www.example.com&pbk=public-key&sid=01&flow=xtls-rprx-vision&fp=chrome#Test")
        let link = try XCTUnwrap(PendingNetNodeShare.links(profile: original.profile, name: "Shared").first)
        let imported = try PendingNetSharedNode.decode(link: link.link)
        // Use the same prefix so node identity does not obscure wire-parameter parity.
        XCTAssertEqual(try original.profile.singBoxProxyOutbounds(tagPrefix: "test"),
                       try imported.profile.singBoxProxyOutbounds(tagPrefix: "test"))
        let query = try XCTUnwrap(URLComponents(string: link.link)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "flow" }?.value, "xtls-rprx-vision")
        XCTAssertEqual(query.first { $0.name == "fp" }?.value, "chrome")
        XCTAssertEqual(query.first { $0.name == "type" }?.value, "tcp")
    }

    func testShareRoundTripsSecretsAndIPv6() throws {
        for source in [
            "vless://uuid@[2001:db8::1]:443?security=reality&sni=example.com&pbk=key&sid=ff&flow=xtls-rprx-vision#台北",
            "hysteria2://a%3Ab%40c%2F%3F%23%25@[2001:db8::2]:8443?sni=example.com&obfs=salamander&obfs-password=a%26b%2Bc&pinsha256=abababababababababababababababababababababababababababababababab&pendingnet-spki=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D#台北"
        ] {
            let original = try PendingNetSharedNode.decode(link: source)
            let links = try PendingNetNodeShare.links(profile: original.profile, name: original.record.name)
            let decoded = try PendingNetSharedNode.decode(link: XCTUnwrap(links.first).link)
            XCTAssertEqual(decoded.profile.protocols, original.profile.protocols)
            XCTAssertEqual(decoded.record.name, original.record.name)
        }
    }
}

extension PendingNetSharedNodeTests {
    func testCertificateFingerprintIsNotMisreadAsSPKIAndUnpinnedTLSIsValidated() throws {
        XCTAssertThrowsError(try PendingNetSharedNode.decode(link: "hy2://pw@host.example:443?pinSHA256=" + String(repeating: "ab", count: 32)))
        XCTAssertThrowsError(try PendingNetSharedNode.decode(link: "hy2://pw@host.example:443?insecure=1"))
        let node = try PendingNetSharedNode.decode(link: "hy2://pw@host.example:443?sni=host.example")
        let runtime = try node.runtimeServer()
        let outbounds = try XCTUnwrap(JSONSerialization.jsonObject(with: runtime.proxyOutbounds) as? [[String: Any]])
        let object = try XCTUnwrap(outbounds.first)
        let tls = try XCTUnwrap(object["tls"] as? [String: Any])
        XCTAssertEqual(tls["insecure"] as? Bool, false)
    }
}
