import XCTest
@testable import SBTallyCore

final class PendingNetStatsServiceSecretTests: XCTestCase {
    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-secret-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsAndTrims() throws {
        let url = try temporaryFile("  hunter2\n")
        XCTAssertEqual(PendingNetStatsService.readSecret(at: url), "hunter2")
    }

    func testMissingFileIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")
        XCTAssertNil(PendingNetStatsService.readSecret(at: url))
    }

    /// 空文件不是「密钥是空串」，是「还没有密钥」—— 拿空串去认证只会被 401。
    func testBlankFileIsNil() throws {
        let url = try temporaryFile("\n   \n")
        XCTAssertNil(PendingNetStatsService.readSecret(at: url))
    }

    /// 引擎重新生成密钥之后，下一次读就得是新的那份。
    func testRereadsAfterRotation() throws {
        let url = try temporaryFile("old")
        XCTAssertEqual(PendingNetStatsService.readSecret(at: url), "old")
        try "new".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(PendingNetStatsService.readSecret(at: url), "new")
    }
}

final class PendingNetStatsServicePortTests: XCTestCase {
    func testFreeDefaultPortIsUsed() {
        let outcome = PendingNetStatsService.choosePort { _ in .free }
        XCTAssertEqual(outcome, .use(PendingNetStatsService.defaultPort))
    }

    /// 默认端口上蹲着另一份 sbtally = 老残留。接管它，而不是躲到别的端口去 ——
    /// 躲开只会让两个采集器同时写一个 SQLite 库。
    func testLegacyCollectorOnDefaultPortIsTakenOver() {
        let outcome = PendingNetStatsService.choosePort { port in
            port == PendingNetStatsService.defaultPort ? .sbtally : .free
        }
        XCTAssertEqual(outcome, .takeOverLegacy(PendingNetStatsService.defaultPort))
    }

    func testForeignDefaultPortFallsForwardToFirstFree() {
        let outcome = PendingNetStatsService.choosePort { port in
            port <= PendingNetStatsService.defaultPort + 1 ? .foreign : .free
        }
        XCTAssertEqual(outcome, .use(PendingNetStatsService.defaultPort + 2))
    }

    /// 非默认端口上的 sbtally 不是我们放的，也就不该被我们收掉。
    func testLegacyCollectorOnFallbackPortIsNotTakenOver() {
        let candidates = [7777, 7778, 7779]
        let outcome = PendingNetStatsService.choosePort(candidates: candidates) { port in
            switch port {
            case 7777: return .foreign
            case 7778: return .sbtally
            default: return .free
            }
        }
        XCTAssertEqual(outcome, .use(7779))
    }

    func testAllOccupiedReportsCandidates() {
        let candidates = [7777, 7778]
        let outcome = PendingNetStatsService.choosePort(candidates: candidates) { _ in .foreign }
        XCTAssertEqual(outcome, .allOccupied(candidates))
    }
}

final class PendingNetStatsServiceLegacyAgentTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testNothingToDoWhenAbsent() {
        XCTAssertEqual(
            PendingNetStatsService.LegacyAgent.plan(plistExists: false, isLoaded: false, home: home),
            .nothingToDo
        )
    }

    /// 手工 bootstrap 过、plist 已经不在原处：卸掉就行，没有文件要挪。
    func testLoadedWithoutPlistOnlyBootsOut() {
        XCTAssertEqual(
            PendingNetStatsService.LegacyAgent.plan(plistExists: false, isLoaded: true, home: home),
            .bootOut
        )
    }

    /// plist 还在就必须挪走 —— 只 bootout 的话下次登录 launchd 又把它拉起来。
    func testPlistPresentIsArchivedEvenWhenNotLoaded() {
        let plist = home.appendingPathComponent("Library/LaunchAgents/io.sbtally.daemon.plist")
        let archive = home.appendingPathComponent(
            "Library/LaunchAgents/io.sbtally.daemon.plist.pendingnet-disabled")
        XCTAssertEqual(
            PendingNetStatsService.LegacyAgent.plan(plistExists: true, isLoaded: false, home: home),
            .bootOutAndArchive(plist: plist, archive: archive)
        )
        XCTAssertEqual(
            PendingNetStatsService.LegacyAgent.plan(plistExists: true, isLoaded: true, home: home),
            .bootOutAndArchive(plist: plist, archive: archive)
        )
    }

    /// 挪走的落点不能还是 .plist —— 不然 launchd 照样把它当一份作业收进去。
    func testArchiveIsNotAPlist() {
        let plist = PendingNetStatsService.LegacyAgent.plistURL(home: home)
        let archive = PendingNetStatsService.LegacyAgent.archiveURL(for: plist)
        XCTAssertEqual(archive.pathExtension, "pendingnet-disabled")
        XCTAssertEqual(archive.deletingPathExtension().lastPathComponent, "io.sbtally.daemon.plist")
    }

    /// 幂等：算两遍得到同一个落点，重复接管不会堆出第二份备份。
    func testArchiveDestinationIsStable() {
        let plist = PendingNetStatsService.LegacyAgent.plistURL(home: home)
        XCTAssertEqual(
            PendingNetStatsService.LegacyAgent.archiveURL(for: plist),
            PendingNetStatsService.LegacyAgent.archiveURL(for: plist)
        )
    }
}

final class PendingNetStatsServiceAvailabilityTests: XCTestCase {
    func testDataWinsOverEverything() {
        XCTAssertEqual(
            PendingNetStatsService.availability(
                engineRunning: false, daemon: .stopped, hasData: true),
            .ready
        )
    }

    func testEngineStoppedIsItsOwnAnswer() {
        XCTAssertEqual(
            PendingNetStatsService.availability(
                engineRunning: false, daemon: .stopped, hasData: false),
            .engineStopped
        )
    }

    func testRunningWithoutDataIsNoTraffic() {
        XCTAssertEqual(
            PendingNetStatsService.availability(
                engineRunning: true, daemon: .running(port: 7777), hasData: false),
            .noTraffic
        )
    }

    /// 统计服务起不来时，原因压过「引擎没跑」—— 那才是用户能动手解决的那件事。
    func testFailureReasonSurvivesAStoppedEngine() {
        XCTAssertEqual(
            PendingNetStatsService.availability(
                engineRunning: false, daemon: .failed("端口 7777 被占用"), hasData: false),
            .unavailable(reason: "端口 7777 被占用")
        )
    }

    /// 服务在跑却读不到，和「这段时间没有流量」是两件事 —— 从前都显示成没有数据。
    func testRunningButUnreadableIsNotNoTraffic() {
        let availability = PendingNetStatsService.availability(
            engineRunning: true, daemon: .running(port: 7801), hasData: false, readFailed: true)
        guard case .unavailable(let reason) = availability else {
            return XCTFail("期望 unavailable，拿到 \(availability)")
        }
        XCTAssertTrue(reason.contains("7801"))
    }

    /// 有数据的时候，一次读失败不该把已经拿到的东西盖掉。
    func testReadFailureDoesNotHideExistingData() {
        XCTAssertEqual(
            PendingNetStatsService.availability(
                engineRunning: true, daemon: .running(port: 7777), hasData: true, readFailed: true),
            .ready
        )
    }

    func testEveryEmptyStateSaysSomethingActionable() {
        let cases: [PendingNetStatsService.Availability] = [
            .engineStopped, .noTraffic, .unavailable(reason: "端口 7777 被占用"),
        ]
        for availability in cases {
            let message = PendingNetStatsService.emptyMessage(for: availability, subject: "流量")
            XCTAssertFalse(message.title.isEmpty)
            XCTAssertFalse(message.detail.isEmpty)
            XCTAssertNotEqual(message.title, "统计服务尚未启用")
        }
    }

    func testFailureMessageCarriesTheReason() {
        let message = PendingNetStatsService.emptyMessage(
            for: .unavailable(reason: "端口 7777 被 foobar 占用"), subject: "流量")
        XCTAssertTrue(message.detail.contains("foobar"))
    }
}
