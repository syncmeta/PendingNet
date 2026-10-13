import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetClientExportTests: XCTestCase {
    func profile() throws -> PendingNetNodeProfile {
        var profile = try PendingNetSharedNode.decode(link: "vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443?security=reality&sni=www.example.com&pbk=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI&sid=abcdef12&flow=xtls-rprx-vision#Test").profile
        let hy = try PendingNetSharedNode.decode(link: "hysteria2://user%3Asecret@203.0.113.10:8443?sni=www.example.com&obfs=salamander&obfs-password=fixture#Test").profile
        profile.protocols += hy.protocols
        return profile
    }
    func testExportAllModesProtocolsAndLANWithLockedKernel() throws {
        let binary = try XCTUnwrap(pendingNetSingBoxForTests())
        let profile = try profile()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for platform in PendingNetClientExportOptions.Platform.allCases {
            for mode in PendingNetClientExportOptions.Mode.allCases {
                for protocolID in profile.protocols.map(\.id) + ["mix"] {
                    for lan in [false, true] {
                        var options = PendingNetClientExportOptions()
                        options.platform = platform; options.mode = mode; options.protocolID = protocolID; options.port = 1088; options.allowsLAN = lan
                        let data = try PendingNetClientExport.make(profile: profile, options: options)
                        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
                        let mixed = try XCTUnwrap(inbounds.first { $0["type"] as? String == "mixed" })
                        XCTAssertEqual(mixed["listen_port"] as? Int, 1088)
                        XCTAssertEqual(mixed["listen"] as? String, lan ? "0.0.0.0" : "127.0.0.1")
                        XCTAssertEqual(mixed["set_system_proxy"] as? Bool == true, mode == .sysproxy)
                        XCTAssertEqual(inbounds.contains { $0["type"] as? String == "tun" }, mode == .tun)
                        XCTAssertEqual((root["route"] as? [String: Any])?["auto_detect_interface"] as? Bool, true)
                        let path = directory.appendingPathComponent("fixture.json")
                        try data.write(to: path)
                        let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = ["check", "-c", path.path]
                        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
                        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                        XCTAssertEqual(process.terminationStatus, 0, "\(platform)/\(mode)/\(protocolID): \(String(decoding: output, as: UTF8.self))")
                    }
                }
            }
        }
    }
    func testOfflineProtocolIsAppliedToNextStartupAndRejectsRemovedMember() throws {
        let suite = "protocol-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PendingNetProtocolPreferences(defaults: defaults)
        let runtime = try profile().runtimeServer(name: "test")
        let choice = try prefs.capture(runtime: runtime)
        let desired = choice.members[1]
        XCTAssertNotNil(prefs.select(desired, in: choice))
        XCTAssertEqual(PendingNetProtocolPreferences(defaults: defaults).load()?.selected, desired)
        let config = try PendingNetTunnelConfig.make(runtimeServer: runtime, routeMode: .global, ruleSetDirectory: "/tmp/rules", cachePath: "/tmp/cache.db")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: prefs.applying(to: config)) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.first { $0["tag"] as? String == choice.selectorTag }?["default"] as? String, desired)
        XCTAssertNil(prefs.select("removed-protocol", in: choice))
    }
    func testLanguageChoiceAndSystemResetOnlyChangeAppDefaults() {
        let suite = "language-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PendingNetLanguagePreferences.save(.traditional, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hant"])
        PendingNetLanguagePreferences.save(.system, defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }
}
