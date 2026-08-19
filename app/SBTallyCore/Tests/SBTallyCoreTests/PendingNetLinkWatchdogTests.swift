import XCTest
@testable import SBTallyCore

private let wired = PendingNetLinkSnapshot(
    primaryInterface: "en7", primaryAddress: "192.168.1.17", router: "192.168.1.2")
private let wireless = PendingNetLinkSnapshot(
    primaryInterface: "en0", primaryAddress: "192.168.5.23", router: "192.168.5.1")
private let offline = PendingNetLinkSnapshot()

final class PendingNetLinkWatchdogTests: XCTestCase {
    /// 第一次取值只当基线：helper 刚起来不该把一台好好的引擎踢一遍。
    func testFirstReadingOnlyRecordsBaseline() {
        var watchdog = PendingNetLinkWatchdog()
        XCTAssertEqual(watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0), .idle)
        XCTAssertEqual(watchdog.lastSnapshot, wired)
        XCTAssertNil(watchdog.lastRestart)
    }

    /// 链路没变，问多少次都是没事。
    func testUnchangedLinkStaysIdle() {
        var watchdog = PendingNetLinkWatchdog()
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        XCTAssertEqual(watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 10), .idle)
        XCTAssertEqual(watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 999), .idle)
    }

    /// 有线切无线：先去抖，抖够了才重启。
    func testWiredToWirelessRestartsAfterDebounce() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)

        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 100),
            .wait(until: 103))
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 102.9),
            .wait(until: 103))

        guard case .restart(let reason) = watchdog.evaluate(
            snapshot: wireless, engineShouldRun: true, at: 103)
        else { return XCTFail("去抖到点后应该重启") }
        XCTAssertTrue(reason.contains("en7(192.168.1.17)"), reason)
        XCTAssertTrue(reason.contains("en0(192.168.5.23)"), reason)
        XCTAssertEqual(watchdog.lastRestart, 103)
    }

    /// 同一块网卡换了网段也算换了链路——旧源地址一样会绑死。
    func testSameInterfaceNewAddressAlsoCounts() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        let renumbered = PendingNetLinkSnapshot(
            primaryInterface: "en7", primaryAddress: "10.0.0.9", router: "10.0.0.1")
        _ = watchdog.evaluate(snapshot: renumbered, engineShouldRun: true, at: 10)
        guard case .restart = watchdog.evaluate(
            snapshot: renumbered, engineShouldRun: true, at: 13)
        else { return XCTFail("换网段也要自愈") }
    }

    /// 还在抖的时候不能重启：每看到一次新变化，去抖窗口重新拉满。
    func testFlappingLinkKeepsResettingDebounce() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)

        XCTAssertEqual(
            watchdog.evaluate(snapshot: offline, engineShouldRun: true, at: 100),
            .wait(until: 103))
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 102),
            .wait(until: 105))
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 104),
            .wait(until: 105))
        guard case .restart = watchdog.evaluate(
            snapshot: wireless, engineShouldRun: true, at: 105)
        else { return XCTFail("抖停了就该重启") }
    }

    /// 中间态（线拔了、Wi-Fi 还没上来）不重启：重启到一个没有默认路由的系统里没意义。
    func testOfflineNeverRestartsAndKeepsWaiting() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        _ = watchdog.evaluate(snapshot: offline, engineShouldRun: true, at: 100)

        XCTAssertEqual(
            watchdog.evaluate(snapshot: offline, engineShouldRun: true, at: 103),
            .wait(until: 106))
        XCTAssertEqual(
            watchdog.evaluate(snapshot: offline, engineShouldRun: true, at: 200),
            .wait(until: 203))
        XCTAssertNil(watchdog.lastRestart)

        // 新网卡一上来，去抖窗口重新起算，然后才自愈。
        _ = watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 210)
        guard case .restart(let reason) = watchdog.evaluate(
            snapshot: wireless, engineShouldRun: true, at: 213)
        else { return XCTFail("新链路站稳后应该重启") }
        // 日志里说的是「从有线变成无线」，不是「从没网变成无线」。
        XCTAssertTrue(reason.contains("en7(192.168.1.17)"), reason)
    }

    /// 节流：30 秒内最多自愈一次，第二次变化推迟到窗口结束，而不是被丢掉。
    func testThrottleDefersRatherThanDropsTheSecondChange() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        _ = watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 100)
        guard case .restart = watchdog.evaluate(
            snapshot: wireless, engineShouldRun: true, at: 103)
        else { return XCTFail("第一次该重启") }

        // 立刻又换回有线：去抖过了，但节流窗口还没开。
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 110)
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 113),
            .wait(until: 133))
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 132),
            .wait(until: 133))
        guard case .restart = watchdog.evaluate(
            snapshot: wired, engineShouldRun: true, at: 133)
        else { return XCTFail("节流窗口过了要补上这次自愈") }
        XCTAssertEqual(watchdog.lastRestart, 133)
    }

    /// 用户自己停掉的引擎不该被自愈拉起来。
    func testStoppedEngineIsNeverRestarted() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: false, at: 100), .idle)
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: false, at: 200), .idle)
        XCTAssertNil(watchdog.lastRestart)
    }

    /// 停着的时候基线要跟上：再启动时不能拿一份过期基线立刻判成「变了」。
    func testStoppedEngineStillAdoptsBaseline() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        _ = watchdog.evaluate(snapshot: wireless, engineShouldRun: false, at: 100)
        XCTAssertEqual(watchdog.lastSnapshot, wireless)
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 200), .idle)
        XCTAssertNil(watchdog.lastRestart)
    }

    /// 一次变化只兑现一次重启，后面的复查不该再踢一遍。
    func testRestartIsNotRepeatedForTheSameChange() {
        var watchdog = PendingNetLinkWatchdog(debounce: 3, throttle: 30)
        _ = watchdog.evaluate(snapshot: wired, engineShouldRun: true, at: 0)
        _ = watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 100)
        guard case .restart = watchdog.evaluate(
            snapshot: wireless, engineShouldRun: true, at: 103)
        else { return XCTFail("该重启") }
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 104), .idle)
        XCTAssertEqual(
            watchdog.evaluate(snapshot: wireless, engineShouldRun: true, at: 500), .idle)
    }

    func testSnapshotOnlineAndDescription() {
        XCTAssertTrue(wired.isOnline)
        XCTAssertFalse(offline.isOnline)
        XCTAssertFalse(PendingNetLinkSnapshot(primaryInterface: "").isOnline)
        XCTAssertEqual(wired.describedForLog, "en7(192.168.1.17)")
        XCTAssertEqual(offline.describedForLog, "无主网卡")
        XCTAssertEqual(PendingNetLinkSnapshot(primaryInterface: "en3").describedForLog, "en3")
    }
}
