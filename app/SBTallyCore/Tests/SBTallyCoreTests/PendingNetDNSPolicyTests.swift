import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetDNSPolicyTests: XCTestCase {
    func testTunnelDNSMustBePresentBeforeApplyingRoutes() throws {
        XCTAssertThrowsError(try PendingNetDNSPolicy.requireTunnelServers([]))
        XCTAssertThrowsError(try PendingNetDNSPolicy.requireTunnelServers(["", " "]))
        XCTAssertEqual(try PendingNetDNSPolicy.requireTunnelServers(["172.19.0.2"]), ["172.19.0.2"])
    }

    func testPartialRuleDownloadsDoNotCreateDanglingDNSReferences() throws {
        // geosite-cn alone cannot enable Whitelist (geoip-cn is also needed).
        let data = try PendingNetProxyOnlyConfig.make(controlSecret: "test", cachePath: "/tmp/cache",
            ruleSets: .init(directory: "/tmp/not-downloaded", availableTags: ["geosite-cn"]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let encoded = try JSONSerialization.data(withJSONObject: dns)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("geosite-cn"))
        let binary = try XCTUnwrap(pendingNetSingBoxForTests())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }

    func testGeneratedSplitPolicyMigrationPreservesCustomRulesAndIsIdempotent() throws {
        let old = Data(#"{"dns":{"rules":[{"rule_set":["geosite-cn"],"server":"dns-direct"}]},"route":{"rule_set":[{"tag":"geosite-cn"},{"tag":"geosite-gfw"}],"default_domain_resolver":{"server":"dns-proxy","strategy":"prefer_ipv4"},"rules":[{"action":"sniff"},{"rule_set":["geosite-cn"],"action":"resolve","server":"dns-direct","strategy":"prefer_ipv4"},{"action":"resolve","strategy":"prefer_ipv4"},{"domain":["custom.test"],"outbound":"direct"}]}}"#.utf8)
        let migrated = try PendingNetRootConfig.migratingGeneratedDNSPolicy(in: old)
        XCTAssertNotEqual(old, migrated)
        XCTAssertEqual(try PendingNetRootConfig.migratingGeneratedDNSPolicy(in: migrated), migrated)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual((route["rules"] as? [[String: Any]])?.last?["domain"] as? [String], ["custom.test"])
        let custom = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "\"rules\":[{\"rule_set\":[\"geosite-cn\"],\"server\":\"dns-direct\"}]", with: "\"rules\":[]").utf8)
        XCTAssertEqual(try PendingNetRootConfig.migratingGeneratedDNSPolicy(in: custom), custom)
    }

    func testPortOnlyUpgradeRetainsCredentialsAndCustomDNS() throws {
        let old = Data(#"{"route":{"rules":[{"action":"sniff"},{"clash_mode":"Global","outbound":"proxy"}]},"outbounds":[{"type":"vless","uuid":"fixture-credential"}]}"#.utf8)
        let migrated = try PendingNetProxyOnlyConfig.migratingMissingDNS(in: old)
        XCTAssertTrue(String(decoding: migrated, as: UTF8.self).contains("fixture-credential"))
        XCTAssertEqual(try PendingNetProxyOnlyConfig.migratingMissingDNS(in: migrated), migrated)
        let custom = Data(#"{"dns":{"final":"custom"},"route":{"rules":[]}}"#.utf8)
        XCTAssertEqual(try PendingNetProxyOnlyConfig.migratingMissingDNS(in: custom), custom)
    }

    func testEveryMacModeUsesEncryptedResolversWithoutBootstrapLoop() throws {
        for data in [
            try PendingNetRootConfig.make(enableTUN: true, controlSecret: "test", cachePath: "/tmp/cache"),
            try PendingNetRootConfig.make(enableTUN: false, controlSecret: "test", cachePath: "/tmp/cache"),
            try PendingNetProxyOnlyConfig.make(controlSecret: "test", cachePath: "/tmp/cache"),
        ] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let dns = try XCTUnwrap(root["dns"] as? [String: Any])
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            XCTAssertEqual(servers.count, 2)
            for server in servers {
                XCTAssertEqual(server["type"] as? String, "https")
                XCTAssertEqual(server["path"] as? String, "/dns-query")
                XCTAssertEqual((server["tls"] as? [String: Any])?["enabled"] as? Bool, true)
            }
            let route = try XCTUnwrap(root["route"] as? [String: Any])
            XCTAssertEqual((route["default_domain_resolver"] as? [String: Any])?["server"] as? String, "dns-direct")
        }
    }

    func testOldGeneratedUDPResolverMigratesButCustomResolverSurvives() throws {
        let original = Data(#"{"dns":{"servers":[{"type":"udp","tag":"dns-direct","server":"223.5.5.5","server_port":53},{"type":"udp","tag":"custom","server":"192.0.2.53"}]}}"#.utf8)
        let migrated = try PendingNetRootConfig.migratingLegacyLocalDNS(in: original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(servers[0]["type"] as? String, "https")
        XCTAssertEqual(servers[1]["type"] as? String, "udp")
        XCTAssertEqual(try PendingNetRootConfig.migratingLegacyLocalDNS(in: migrated), migrated)
    }
}
