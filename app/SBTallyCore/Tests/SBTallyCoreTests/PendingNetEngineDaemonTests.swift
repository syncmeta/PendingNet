import XCTest
@testable import SBTallyCore

final class PendingNetEngineDaemonTests: XCTestCase {
    private let bundled = "/Applications/PendingNet.app/Contents/MacOS/sing-box"

    func testJobRunsTheEngineItWasGiven() throws {
        let data = try PendingNetEngineDaemon.plistData(
            enginePath: bundled,
            configPath: "/usr/local/etc/sbtally/master.json",
            workingDirectory: "/usr/local/etc/sbtally"
        )
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(root["Label"] as? String, "io.sbtally.singbox")
        XCTAssertEqual(
            root["ProgramArguments"] as? [String],
            [bundled, "run", "-c", "/usr/local/etc/sbtally/master.json"]
        )
        XCTAssertEqual(root["WorkingDirectory"] as? String, "/usr/local/etc/sbtally")
        XCTAssertEqual(root["StandardOutPath"] as? String, "/var/log/sbtally-singbox.log")
        XCTAssertEqual(root["StandardErrorPath"] as? String, "/var/log/sbtally-singbox.log")
    }

    /// 留在 /Library/LaunchDaemons 的作业不能绕过设置页擅自开机接管。
    func testJobOnlyStartsWhenTheAppExplicitlyStartsIt() throws {
        let job = PendingNetEngineDaemon.jobDefinition(
            enginePath: bundled,
            configPath: "/usr/local/etc/sbtally/master.json",
            workingDirectory: "/usr/local/etc/sbtally"
        )
        XCTAssertEqual(job["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(job["KeepAlive"] as? Bool, false)
    }

    /// 盘上那份指着哪儿要读得出来，才判断得了「现在这份已经是对的、不用重写」。
    func testReadsBackTheDeclaredEngine() throws {
        let data = try PendingNetEngineDaemon.plistData(
            enginePath: bundled,
            configPath: "/usr/local/etc/sbtally/master.json",
            workingDirectory: "/usr/local/etc/sbtally"
        )
        XCTAssertEqual(PendingNetEngineDaemon.declaredEnginePath(plistData: data), bundled)
    }

    /// 老脚本写的那份（`Program` 是 homebrew 那条）也要读得出来 —— 升级到自带引擎
    /// 的这一版时，正是靠这个看出盘上那份该换掉了。
    func testReadsTheLegacyHomebrewJob() throws {
        let legacy = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>io.sbtally.singbox</string>
          <key>ProgramArguments</key><array>
            <string>/opt/homebrew/bin/sing-box</string><string>run</string>
            <string>-c</string><string>/usr/local/etc/sbtally/master.json</string>
          </array>
        </dict></plist>
        """
        XCTAssertEqual(
            PendingNetEngineDaemon.declaredEnginePath(plistData: Data(legacy.utf8)),
            "/opt/homebrew/bin/sing-box"
        )
    }

    func testGarbageDeclaresNothing() {
        XCTAssertNil(PendingNetEngineDaemon.declaredEnginePath(plistData: Data("nope".utf8)))
    }

    func testFreshInstallCreatesBothRootVariantsAndActiveConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-root-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try PendingNetEngineDaemon.prepareConfigDirectory(
            at: directory.path,
            preferredMode: "tun",
            makeControlSecret: { "fresh-secret" }
        )

        let tun = try Data(contentsOf: directory.appendingPathComponent("master-tun.json"))
        let noTun = try Data(contentsOf: directory.appendingPathComponent("master-notun.json"))
        let active = try Data(contentsOf: directory.appendingPathComponent("master.json"))
        XCTAssertTrue(Self.hasTUN(tun))
        XCTAssertFalse(Self.hasTUN(noTun))
        XCTAssertEqual(active, tun)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("control-secret"), encoding: .utf8),
            "fresh-secret\n"
        )
        XCTAssertEqual(try Self.permissions(directory), 0o700)
        for name in ["control-secret", "master-tun.json", "master-notun.json", "master.json"] {
            XCTAssertEqual(try Self.permissions(directory.appendingPathComponent(name)), 0o600)
        }
    }

    func testPreparingRootConfigDirectoryIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-root-idempotent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try PendingNetEngineDaemon.prepareConfigDirectory(
            at: directory.path,
            preferredMode: "sysproxy",
            makeControlSecret: { "first-secret" }
        )
        let names = ["control-secret", "master-tun.json", "master-notun.json", "master.json"]
        let before = try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })

        try PendingNetEngineDaemon.prepareConfigDirectory(
            at: directory.path,
            preferredMode: "tun",
            makeControlSecret: { "must-not-be-used" }
        )
        let after = try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
        XCTAssertEqual(after, before)
    }

    func testLegacyMasterSeedsMissingVariantsWithoutLosingOutbounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-root-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"{"inbounds":[{"type":"mixed","listen_port":2080}],"outbounds":[{"type":"direct","tag":"kept-vps"}]}"#.utf8)
        try legacy.write(to: directory.appendingPathComponent("master.json"))

        try PendingNetEngineDaemon.prepareConfigDirectory(
            at: directory.path,
            preferredMode: "sysproxy",
            makeControlSecret: { "legacy-secret" }
        )

        for name in ["master-tun.json", "master-notun.json"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tags = (root["outbounds"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
            XCTAssertEqual(tags, ["kept-vps"])
        }
        XCTAssertTrue(Self.hasTUN(
            try Data(contentsOf: directory.appendingPathComponent("master-tun.json"))))
        XCTAssertFalse(Self.hasTUN(
            try Data(contentsOf: directory.appendingPathComponent("master-notun.json"))))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("master.json")), legacy)
    }

    private static func hasTUN(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]] else { return false }
        return inbounds.contains { $0["type"] as? String == "tun" }
    }

    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
