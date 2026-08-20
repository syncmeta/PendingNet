import XCTest
@testable import SBTallyCore

final class PendingNetDNSCacheFlushTests: XCTestCase {
    private let dscacheutil = PendingNetDNSCacheFlush.flushDirectoryService
    private let killall = PendingNetDNSCacheFlush.flushMDNSResponder

    /// 四个时刻一个都不能少，而且每个都得说得出自己在引擎的哪一侧。
    func testEveryTriggerHasALabelAndASide() {
        XCTAssertEqual(PendingNetDNSCacheFlush.Trigger.allCases.count, 5)
        // 起来那一侧：启动引擎 / 切换接管模式 / 应用 VPS 配置 / 换网卡自愈。
        for trigger in [
            PendingNetDNSCacheFlush.Trigger.engineStarted,
            .takeoverSwitched,
            .serverConfigurationApplied,
            .linkSelfHealed,
        ] {
            XCTAssertEqual(trigger.moment, .afterEngineUp, "\(trigger) 该在引擎起来之后冲")
        }
        // 停那一侧：残留的 fake-ip 会让直连也废掉，所以这条同样要冲。
        XCTAssertEqual(PendingNetDNSCacheFlush.Trigger.engineStopped.moment, .afterEngineDown)

        let labels = PendingNetDNSCacheFlush.Trigger.allCases.map(\.logLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "日志里两个时刻不能长得一样")
        XCTAssertFalse(labels.contains(where: \.isEmpty))
    }

    /// 主力是 SIGHUP mDNSResponder，辅助是 dscacheutil，而且 DS 那层先清。
    func testCommandsAreTheTwoRootOnlyOnesInOrder() {
        XCTAssertEqual(PendingNetDNSCacheFlush.commands, [dscacheutil, killall])
        XCTAssertEqual(killall.describedForLog, "/usr/bin/killall -HUP mDNSResponder")
        XCTAssertTrue(killall.isRequired)
        XCTAssertEqual(dscacheutil.describedForLog, "/usr/bin/dscacheutil -flushcache")
        XCTAssertFalse(dscacheutil.isRequired)
    }

    func testBothSucceedingIsAPlainFlush() {
        XCTAssertEqual(
            PendingNetDNSCacheFlush.outcome(results: [
                .init(command: dscacheutil, exitCode: 0),
                .init(command: killall, exitCode: 0),
            ]),
            .flushed)
    }

    /// 辅助那条挂了可以不管：缓存已经被主力冲掉了，日志记一笔就行。
    func testDscacheutilFailingIsIgnorable() {
        let outcome = PendingNetDNSCacheFlush.outcome(results: [
            .init(command: dscacheutil, exitCode: 64),
            .init(command: killall, exitCode: 0),
        ])
        XCTAssertEqual(outcome, .degraded(failed: ["/usr/bin/dscacheutil -flushcache"]))
        let line = PendingNetDNSCacheFlush.logLine(trigger: .engineStarted, outcome: outcome)
        XCTAssertTrue(line.contains("启动引擎"), line)
        XCTAssertTrue(line.contains("已冲掉"), line)
        XCTAssertTrue(line.contains("dscacheutil"), line)
    }

    /// 主力挂了才叫失败——但也只是记日志，见下面那条顺序测试：引擎启停不受影响。
    func testMDNSResponderFailingIsARealFailureButOnlyInTheLog() {
        let outcome = PendingNetDNSCacheFlush.outcome(results: [
            .init(command: dscacheutil, exitCode: 0),
            .init(command: killall, exitCode: 1),
        ])
        XCTAssertEqual(outcome, .failed(failed: ["/usr/bin/killall -HUP mDNSResponder"]))
        let line = PendingNetDNSCacheFlush.logLine(trigger: .linkSelfHealed, outcome: outcome)
        XCTAssertTrue(line.contains("换网卡自愈"), line)
        XCTAssertTrue(line.contains("失败"), line)
    }

    /// 两条一起挂，仍然按「主力挂了」报，别把结论说轻了。
    func testBothFailingReportsFailure() {
        XCTAssertEqual(
            PendingNetDNSCacheFlush.outcome(results: [
                .init(command: dscacheutil, exitCode: 64),
                .init(command: killall, exitCode: 1),
            ]),
            .failed(failed: [
                "/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder",
            ]))
    }

    /// 这条是整件事的要害：冲刷必须发生在引擎**起来之后**，不能在之前。
    func testFlushHappensAfterTheEngineIsUpNeverBefore() {
        var steps: [String] = []
        let error = PendingNetDNSCacheFlush.afterEngineUp(
            .takeoverSwitched,
            bringUp: { steps.append("engine-up"); return nil },
            flush: { steps.append("flush(\($0.logLabel))") }
        )
        XCTAssertNil(error)
        XCTAssertEqual(steps, ["engine-up", "flush(切换接管模式)"])
    }

    /// 引擎没起来就别冲：那时候查出来的还走没有代理的上游，冲了当场又被投一遍。
    func testFailedStartFlushesNothingAndKeepsTheError() {
        var flushes: [PendingNetDNSCacheFlush.Trigger] = []
        let error = PendingNetDNSCacheFlush.afterEngineUp(
            .serverConfigurationApplied,
            bringUp: { "sing-box 重启后未进入运行状态" },
            flush: { flushes.append($0) }
        )
        XCTAssertEqual(error, "sing-box 重启后未进入运行状态")
        XCTAssertTrue(flushes.isEmpty)
    }

    /// 停那一侧：先停干净再冲。
    func testFlushHappensAfterTheEngineIsDown() {
        var steps: [String] = []
        let error = PendingNetDNSCacheFlush.afterEngineDown(
            .engineStopped,
            stop: { steps.append("engine-down"); return nil },
            flush: { steps.append("flush(\($0.logLabel))") }
        )
        XCTAssertNil(error)
        XCTAssertEqual(steps, ["engine-down", "flush(停止引擎)"])
    }

    /// 停的时候报了错也照冲：TUN 可能已经拆了一半，缓存里的 fake-ip 更得清掉。
    func testStopFailureStillFlushesAndKeepsTheError() {
        var steps: [String] = []
        let error = PendingNetDNSCacheFlush.afterEngineDown(
            .engineStopped,
            stop: { steps.append("engine-down"); return "bootout 失败" },
            flush: { _ in steps.append("flush") }
        )
        XCTAssertEqual(error, "bootout 失败")
        XCTAssertEqual(steps, ["engine-down", "flush"])
    }
}
