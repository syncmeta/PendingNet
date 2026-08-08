import XCTest
@testable import SBTallyCore

private func makeSuite(_ label: String, _ function: String = #function) -> UserDefaults {
    let suite = "PendingNetLegacyDefaultsMigrationTests.\(function).\(label)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func encodedRecords(_ ids: [String]) -> Data {
    let records = ids.map {
        PairedVPSRecord(
            serverID: $0,
            name: "vps-\($0)",
            endpoint: "https://\($0).example.com:7443",
            certificateSHA256: "sha256:" + String(repeating: "a", count: 64),
            deviceID: "device-\($0)",
            capabilities: ["stats"],
            pairedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
    return try! JSONEncoder().encode(records)
}

final class PendingNetLegacyDefaultsMigrationTests: XCTestCase {
    func testCopiesScalarSettingsIntoTheNewDomain() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(2081, forKey: "pendingnet.local-proxy-port")
        legacy.set(true, forKey: "pendingnet.allow-lan")
        legacy.set("Rule", forKey: "pendingnet.route-mode")
        legacy.set(true, forKey: "PendingNetHelperWasEnabled")

        _ = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertEqual(target.integer(forKey: "pendingnet.local-proxy-port"), 2081)
        XCTAssertTrue(target.bool(forKey: "pendingnet.allow-lan"))
        XCTAssertEqual(target.string(forKey: "pendingnet.route-mode"), "Rule")
        XCTAssertTrue(target.bool(forKey: "PendingNetHelperWasEnabled"))
    }

    func testReturnsLegacyPairedServersForTheStoreToAdopt() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(encodedRecords(["alpha", "beta"]), forKey: PairedVPSStore.defaultLocalKey)

        let adopted = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertEqual(adopted.map(\.serverID).sorted(), ["alpha", "beta"])
        // 记录本身不由迁移写进新域 —— 那是 `PairedVPSStore.adoptLegacy` 的活，
        // 绕过去直接写 key 会跳过和 iCloud 那边的合并。
        XCTAssertNil(target.data(forKey: PairedVPSStore.defaultLocalKey))
    }

    func testLeavesTheLegacyDomainUntouched() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(2081, forKey: "pendingnet.local-proxy-port")
        legacy.set(encodedRecords(["alpha"]), forKey: PairedVPSStore.defaultLocalKey)

        _ = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertEqual(legacy.integer(forKey: "pendingnet.local-proxy-port"), 2081)
        XCTAssertNotNil(legacy.data(forKey: PairedVPSStore.defaultLocalKey))
        XCTAssertFalse(legacy.bool(forKey: PendingNetLegacyDefaultsMigration.completionKey))
    }

    func testRunsOnlyOnce() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(2081, forKey: "pendingnet.local-proxy-port")
        legacy.set(encodedRecords(["alpha"]), forKey: PairedVPSStore.defaultLocalKey)

        _ = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)
        // 用户在新版里把端口改回默认，然后重启 App：第二次不该把旧值搬回来。
        target.set(2080, forKey: "pendingnet.local-proxy-port")

        let secondRun = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertEqual(target.integer(forKey: "pendingnet.local-proxy-port"), 2080)
        XCTAssertTrue(secondRun.isEmpty)
    }

    func testNeverOverwritesAValueTheNewDomainAlreadyHas() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(2081, forKey: "pendingnet.local-proxy-port")
        target.set(3000, forKey: "pendingnet.local-proxy-port")

        _ = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertEqual(target.integer(forKey: "pendingnet.local-proxy-port"), 3000)
    }

    func testMarksItselfDoneEvenWhenThereIsNothingToMigrate() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")

        let adopted = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        XCTAssertTrue(adopted.isEmpty)
        XCTAssertTrue(target.bool(forKey: PendingNetLegacyDefaultsMigration.completionKey))
    }

    func testIgnoresUnreadableLegacyPairedServers() {
        let legacy = makeSuite("legacy")
        let target = makeSuite("target")
        legacy.set(Data("not json".utf8), forKey: PairedVPSStore.defaultLocalKey)
        legacy.set(2081, forKey: "pendingnet.local-proxy-port")

        let adopted = PendingNetLegacyDefaultsMigration.run(from: legacy, into: target)

        // 一份读不懂的存档不该把整次迁移拖垮 —— 其余设置照搬。
        XCTAssertTrue(adopted.isEmpty)
        XCTAssertEqual(target.integer(forKey: "pendingnet.local-proxy-port"), 2081)
    }
}
