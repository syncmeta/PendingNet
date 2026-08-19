import XCTest
@testable import SBTallyCore

/// 本机 /var/log/sbtally-singbox.log 里那次废掉的启动，原文照抄。
private let unboundStartup = """
+0800 2026-08-19 10:22:53 INFO router: updated default interface
+0800 2026-08-19 10:22:53 ERROR network: missing default interface
+0800 2026-08-19 10:22:53 ERROR dns/local[dns-local]: fetch DNS servers: dhcp: prepare interface: missing default interface
"""
private let goodStartup = """
+0800 2026-08-19 10:23:10 INFO router: updated default interface: en7
+0800 2026-08-19 10:23:10 INFO sing-box started (0.31s)
"""

final class PendingNetEngineHealthTests: XCTestCase {
    func testHealthyStartupNeedsNothing() {
        XCTAssertFalse(PendingNetEngineHealth.isUnbound(freshLog: goodStartup))
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(freshLog: goodStartup, retriesSoFar: 0), .healthy)
        // 一个字没写出来也算好的：宁可漏判，也不能拿没有证据的日志去重启一遍。
        XCTAssertEqual(PendingNetEngineHealth.verdict(freshLog: "", retriesSoFar: 0), .healthy)
    }

    func testUnboundStartupIsRetriedTwiceThenGivenUp() {
        XCTAssertTrue(PendingNetEngineHealth.isUnbound(freshLog: unboundStartup))
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(freshLog: unboundStartup, retriesSoFar: 0),
            .retry(attempt: 1, after: PendingNetEngineHealth.defaultRetryDelay))
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(freshLog: unboundStartup, retriesSoFar: 1),
            .retry(attempt: 2, after: PendingNetEngineHealth.defaultRetryDelay))
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(freshLog: unboundStartup, retriesSoFar: 2),
            .giveUp(afterRestarts: 3))
    }

    func testRetryBudgetIsConfigurable() {
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(
                freshLog: unboundStartup, retriesSoFar: 0, maxRetries: 0),
            .giveUp(afterRestarts: 1))
        XCTAssertEqual(
            PendingNetEngineHealth.verdict(
                freshLog: unboundStartup, retriesSoFar: 1, maxRetries: 5, retryDelay: 7),
            .retry(attempt: 2, after: 7))
    }

    /// 只看新写进去的那一段：历史上那几条早就躺在文件里，不能算这次的账。
    func testOnlyTheFreshTailCounts() {
        XCTAssertEqual(
            PendingNetEngineHealth.tailOffset(previousSize: 1024, currentSize: 4096), 1024)
        XCTAssertEqual(
            PendingNetEngineHealth.tailOffset(previousSize: 0, currentSize: 4096), 0)
        // 中间被轮转原地截断过：旧的大小已经在文件外面了，从头读。
        XCTAssertEqual(
            PendingNetEngineHealth.tailOffset(previousSize: 160_000_000, currentSize: 512), 0)
        XCTAssertEqual(
            PendingNetEngineHealth.tailOffset(previousSize: 4096, currentSize: 4096), 4096)
    }
}
