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

final class PendingNetStatsServiceCollectorOwnerTests: XCTestCase {
    func testNobodyCollectsWithoutAnEngine() {
        for takeover in ["local", "sysproxy", "tun"] {
            XCTAssertEqual(
                PendingNetStatsService.collectorOwner(takeover: takeover, engineRunning: false),
                .nobody
            )
        }
    }

    func testAppOwnsPortOnlyMode() {
        XCTAssertEqual(
            PendingNetStatsService.collectorOwner(takeover: "local", engineRunning: true),
            .app
        )
    }

    /// TUN 和系统代理那份引擎是特权助手用 root 起的，密钥不出助手 —— 采集器只能
    /// 由助手代劳。这两种模式恰恰是最该有统计的（按应用分流量靠的就是 TUN）。
    func testHelperOwnsRootEngineModes() {
        for takeover in ["tun", "sysproxy"] {
            XCTAssertEqual(
                PendingNetStatsService.collectorOwner(takeover: takeover, engineRunning: true),
                .helper
            )
        }
    }

    /// 同一时刻只能有一个 owner —— 两边各起一个就会抢同一个端口和同一个库。
    func testOwnerIsNeverAmbiguous() {
        for takeover in ["local", "sysproxy", "tun", "什么鬼"] {
            for running in [true, false] {
                let owner = PendingNetStatsService.collectorOwner(
                    takeover: takeover, engineRunning: running)
                XCTAssertEqual([owner].count, 1)
            }
        }
    }
}

final class PendingNetStatsServiceDaemonArgumentsTests: XCTestCase {
    /// 密钥绝不能出现在命令行上 —— ps 是全机可见的。
    func testSecretNeverAppearsOnTheCommandLine() {
        let viaStdin = PendingNetStatsService.daemonArguments(
            clashAPI: "127.0.0.1:9090", port: 7777,
            databasePath: "/Users/tester/db.sqlite", secret: .standardInput)
        XCTAssertTrue(viaStdin.contains("-secret-stdin"))
        XCTAssertFalse(viaStdin.contains { $0.contains("hunter2") })

        let viaFile = PendingNetStatsService.daemonArguments(
            clashAPI: "127.0.0.1:29090", port: 7777,
            databasePath: "/Users/tester/db.sqlite", secret: .file("/tmp/control-secret"))
        XCTAssertEqual(viaFile.firstIndex(of: "-secret-file").map { viaFile[$0 + 1] },
                       "/tmp/control-secret")
        XCTAssertFalse(viaFile.contains("-secret-stdin"))
    }

    func testListensOnLoopbackOnly() {
        let arguments = PendingNetStatsService.daemonArguments(
            clashAPI: "127.0.0.1:9090", port: 7801,
            databasePath: "/Users/tester/db.sqlite", secret: .standardInput)
        XCTAssertEqual(arguments.firstIndex(of: "-listen").map { arguments[$0 + 1] },
                       "127.0.0.1:7801")
    }

    /// 规则集目录必须显式传空：助手那份目录 root 才写得进去，App 那边另有下载器。
    func testRuleSetManagementIsHandedOff() {
        let arguments = PendingNetStatsService.daemonArguments(
            clashAPI: "127.0.0.1:9090", port: 7777,
            databasePath: "/Users/tester/db.sqlite", secret: .standardInput)
        XCTAssertEqual(arguments.firstIndex(of: "-ruleset-dir").map { arguments[$0 + 1] }, "")
    }

    /// 三种接管方式写同一个库，切一次模式统计不该清零。
    func testDatabasePathIsTheUsersOne() {
        XCTAssertEqual(
            PendingNetStatsService.databasePath(home: "/Users/tester"),
            "/Users/tester/Library/Application Support/sbtally/sbtally.db"
        )
    }
}

final class PendingNetStatsServiceHelperReportTests: XCTestCase {
    func testRunningCarriesThePort() {
        XCTAssertEqual(
            PendingNetStatsService.daemonState(helperRunning: true, port: 7777, failure: nil),
            .running(port: 7777)
        )
    }

    /// 助手说「没在采」而且没给原因 = 引擎本来就没起。那该说「先去连接」，
    /// 不是「统计服务坏了」。
    func testNotRunningWithoutAReasonIsMerelyStopped() {
        XCTAssertEqual(
            PendingNetStatsService.daemonState(helperRunning: false, port: 7777, failure: nil),
            .stopped
        )
        XCTAssertEqual(
            PendingNetStatsService.daemonState(helperRunning: false, port: 7777, failure: "  "),
            .stopped
        )
    }

    func testReasonSurvivesToTheUser() {
        XCTAssertEqual(
            PendingNetStatsService.daemonState(
                helperRunning: false, port: 7777, failure: "统计端口 7777 被别的程序占着。"),
            .failed("统计端口 7777 被别的程序占着。")
        )
    }

    /// 助手报的状态最终要能落成一句有下一步的话。
    func testHelperReportReachesAnActionableMessage() {
        let state = PendingNetStatsService.daemonState(
            helperRunning: false, port: 7777, failure: "统计端口 7777 被别的程序占着。")
        let availability = PendingNetStatsService.availability(
            engineRunning: true, daemon: state, hasData: false)
        let message = PendingNetStatsService.emptyMessage(for: availability, subject: "应用流量")
        XCTAssertTrue(message.detail.contains("7777"))
    }
}
