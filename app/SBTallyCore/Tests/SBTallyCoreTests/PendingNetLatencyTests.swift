import Network
import XCTest
@testable import SBTallyCore

final class PendingNetLatencyTests: XCTestCase {
    private func record(
        endpoint: String = "https://203.0.113.10:7443",
        proxyTCPHost: String? = nil,
        proxyTCPPort: Int? = nil
    ) -> PairedVPSRecord {
        PairedVPSRecord(
            serverID: "s1",
            name: "VPS",
            endpoint: endpoint,
            certificateSHA256: "aa",
            deviceID: "d1",
            capabilities: [],
            proxyTCPHost: proxyTCPHost,
            proxyTCPPort: proxyTCPPort
        )
    }

    private func profile(
        reality: PendingNetNodeProfile.VLESSReality? = nil,
        hysteria2: PendingNetNodeProfile.Hysteria2? = nil
    ) -> PendingNetNodeProfile {
        var protocols: [PendingNetNodeProfile.NodeProtocol] = []
        if let reality {
            protocols.append(.init(
                id: "reality",
                type: "vless-reality",
                displayName: "Reality",
                vlessReality: reality,
                hysteria2: nil
            ))
        }
        if let hysteria2 {
            protocols.append(.init(
                id: "hy2",
                type: "hysteria2",
                displayName: "Hysteria2",
                vlessReality: nil,
                hysteria2: hysteria2
            ))
        }
        return PendingNetNodeProfile(
            version: 1,
            serverID: "s1",
            updatedAt: "now",
            protocols: protocols
        )
    }

    private func reality(server: String = "203.0.113.10", port: Int = 443)
        -> PendingNetNodeProfile.VLESSReality {
        .init(
            server: server,
            serverPort: port,
            uuid: "u",
            flow: "xtls-rprx-vision",
            serverName: "www.cloudflare.com",
            publicKey: "k",
            shortID: "01"
        )
    }

    private func hysteria2(server: String = "203.0.113.10", port: Int = 443)
        -> PendingNetNodeProfile.Hysteria2 {
        .init(
            server: server,
            serverPort: port,
            password: "p",
            obfsType: "salamander",
            obfsPassword: "o",
            serverName: "vps",
            certificatePublicKeySHA256: "bb"
        )
    }

    // MARK: - 测哪个端点

    func testPrefersProxyEntryOverControlPort() {
        let target = PendingNetLatencyTarget.forVPS(
            record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443)
        )
        XCTAssertEqual(target?.host, "203.0.113.10")
        XCTAssertEqual(target?.port, 443)
        XCTAssertEqual(target?.kind, .proxyEntry)
    }

    func testFallsBackToControlPortBeforeNodeProfileArrives() {
        let target = PendingNetLatencyTarget.forVPS(record())
        XCTAssertEqual(target?.host, "203.0.113.10")
        XCTAssertEqual(target?.port, 7443)
        XCTAssertEqual(target?.kind, .controlPort)
    }

    func testControlEndpointWithoutPortUsesHTTPSDefault() {
        let target = PendingNetLatencyTarget.forVPS(record(endpoint: "https://vps.example.com"))
        XCTAssertEqual(target?.port, 443)
    }

    func testUnparsableEndpointHasNoTarget() {
        XCTAssertNil(PendingNetLatencyTarget.forVPS(record(endpoint: "这不是地址")))
    }

    func testOutOfRangeProxyPortFallsBackInsteadOfProbingIt() {
        let target = PendingNetLatencyTarget.forVPS(
            record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 70000)
        )
        XCTAssertEqual(target?.kind, .controlPort)
    }

    func testExplanationNamesTheEndpointItMeasured() {
        let proxy = PendingNetLatencyTarget(host: "203.0.113.10", port: 443, kind: .proxyEntry)
        XCTAssertTrue(proxy.explanation.contains("203.0.113.10:443"))
        XCTAssertTrue(proxy.explanation.contains("代理入口"))
        let control = PendingNetLatencyTarget(host: "203.0.113.10", port: 7443, kind: .controlPort)
        XCTAssertTrue(control.explanation.contains("控制端口"))
    }

    // MARK: - 从节点资料记下代理入口

    func testAdoptsRealityEndpointFromNodeProfile() {
        var stored = record()
        stored.adoptProxyEntry(from: profile(reality: reality(port: 8443), hysteria2: hysteria2()))
        XCTAssertEqual(stored.proxyTCPHost, "203.0.113.10")
        XCTAssertEqual(stored.proxyTCPPort, 8443)
    }

    func testHysteria2OnlyServerKeepsNoTCPEntry() {
        // Hysteria2 是 UDP/QUIC，没有 TCP 握手可以计时。
        var stored = record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443)
        stored.adoptProxyEntry(from: profile(hysteria2: hysteria2()))
        XCTAssertNil(stored.proxyTCPHost)
        XCTAssertNil(stored.proxyTCPPort)
        // 于是延迟退回控制端口，而不是继续测一个已经不存在的服务。
        XCTAssertEqual(PendingNetLatencyTarget.forVPS(stored)?.kind, .controlPort)
    }

    func testProxyEntrySurvivesEncodingRoundTrip() throws {
        var stored = record()
        stored.adoptProxyEntry(from: profile(reality: reality(port: 443)))
        let decoded = try JSONDecoder().decode(
            PairedVPSRecord.self,
            from: JSONEncoder().encode(stored)
        )
        XCTAssertEqual(decoded.proxyTCPHost, "203.0.113.10")
        XCTAssertEqual(decoded.proxyTCPPort, 443)
    }

    func testOldArchiveWithoutProxyEntryStillDecodes() throws {
        let json = """
        {"serverID":"s1","name":"VPS","endpoint":"https://203.0.113.10:7443",
         "certificateSHA256":"aa","deviceID":"d1","capabilities":[]}
        """
        let decoded = try JSONDecoder().decode(PairedVPSRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.proxyTCPHost)
        XCTAssertNil(decoded.proxyTCPPort)
    }

    // MARK: - 失败时说人话

    func testFailureMessagesAreHumanReadable() {
        let target = PendingNetLatencyTarget(host: "203.0.113.10", port: 443, kind: .proxyEntry)
        let refused = PendingNetLatencyFailure.message(
            for: NWError.posix(.ECONNREFUSED), target: target
        )
        XCTAssertTrue(refused.contains("拒绝"))
        XCTAssertTrue(refused.contains("443"))

        let timedOut = PendingNetLatencyFailure.message(
            for: PendingNetLatencyError.timedOut, target: target
        )
        XCTAssertTrue(timedOut.contains("超时"))

        let unreachable = PendingNetLatencyFailure.message(
            for: NWError.posix(.EHOSTUNREACH), target: target
        )
        XCTAssertTrue(unreachable.contains("网络"))

        let dns = PendingNetLatencyFailure.message(
            for: NWError.dns(Int32(kDNSServiceErr_NoSuchRecord)), target: target
        )
        XCTAssertTrue(dns.contains("解析"))
    }

    func testFailureMessagesNeverLeakRawErrorCodes() {
        let target = PendingNetLatencyTarget(host: "203.0.113.10", port: 443, kind: .proxyEntry)
        for error in [NWError.posix(.ECONNREFUSED), NWError.posix(.ETIMEDOUT), NWError.posix(.ENETUNREACH)] {
            let message = PendingNetLatencyFailure.message(for: error, target: target)
            XCTAssertFalse(message.contains("POSIX"), message)
            XCTAssertFalse(message.lowercased().contains("error"), message)
        }
    }

    // MARK: - 测量流程

    @MainActor
    func testSuccessfulMeasurementRemembersNumberAndEndpoint() async {
        let tester = PendingNetLatencyTester(probe: { host, port, _ in
            XCTAssertEqual(host, "203.0.113.10")
            XCTAssertEqual(port, 443)
            return 42
        })
        await tester.measure(record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443))
        XCTAssertEqual(
            tester.outcome(for: "s1"),
            .ok(
                milliseconds: 42,
                target: PendingNetLatencyTarget(host: "203.0.113.10", port: 443, kind: .proxyEntry)
            )
        )
        XCTAssertEqual(tester.outcome(for: "s1")?.rowText, "42 ms")
        XCTAssertFalse(tester.busy)
    }

    @MainActor
    func testFailedMeasurementShowsReasonNotACode() async {
        let tester = PendingNetLatencyTester(probe: { _, _, _ in throw NWError.posix(.ECONNREFUSED) })
        await tester.measure(record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443))
        XCTAssertEqual(tester.outcome(for: "s1")?.rowText, "不通")
        XCTAssertEqual(tester.outcome(for: "s1")?.failureText?.contains("拒绝"), true)
    }

    @MainActor
    func testUnresolvableAddressFailsWithoutProbing() async {
        var probed = false
        let tester = PendingNetLatencyTester(probe: { _, _, _ in
            probed = true
            return 1
        })
        await tester.measure(record(endpoint: "这不是地址"))
        XCTAssertFalse(probed)
        XCTAssertEqual(tester.outcome(for: "s1")?.failureText?.contains(".pdn"), true)
    }

    @MainActor
    func testMeasureAllCoversEveryServer() async {
        let tester = PendingNetLatencyTester(probe: { _, port, _ in port })
        var second = record(proxyTCPHost: "198.51.100.7", proxyTCPPort: 8443)
        second.serverID = "s2"
        await tester.measureAll([record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443), second])
        XCTAssertEqual(tester.outcome(for: "s1")?.rowText, "443 ms")
        XCTAssertEqual(tester.outcome(for: "s2")?.rowText, "8443 ms")
    }

    @MainActor
    func testTimeoutIsHandedToTheProbe() async {
        let tester = PendingNetLatencyTester(timeout: 3, probe: { _, _, timeout in
            XCTAssertEqual(timeout, 3)
            return 1
        })
        await tester.measure(record(proxyTCPHost: "203.0.113.10", proxyTCPPort: 443))
        XCTAssertNotNil(tester.outcome(for: "s1"))
    }
}
