import XCTest
@testable import SBTallyCore

/// 本机 `launchctl print system/io.sbtally.singbox` 的真实输出，掐头去尾。
private let printOutput = """
system/io.sbtally.singbox = {
\tactive count = 1
\tpath = /Library/LaunchDaemons/io.sbtally.singbox.plist
\ttype = LaunchDaemon
\tstate = running

\tprogram = /Applications/PendingNet.app/Contents/MacOS/sing-box
\tworking directory = /usr/local/etc/sbtally

\tpid = 588
\timmediate reason = speculative
\tforks = 0

\tendpoints = {
\t\t"com.apple.something" = {
\t\t\tport = 1
\t\t\tstate = active
\t\t}
\t}
}
"""

final class PendingNetEngineRestartTests: XCTestCase {
    func testParsesThePIDOfTheRunningJob() {
        XCTAssertEqual(PendingNetEngineRestart.parsePID(launchctlPrintOutput: printOutput), 588)
    }

    /// job 在但没进程（bootout 过、KeepAlive 还没拉起来）：没有 pid 那一行。
    func testNoPIDWhenNothingIsRunning() {
        let stopped = """
        system/io.sbtally.singbox = {
        \tstate = waiting
        \tpath = /Library/LaunchDaemons/io.sbtally.singbox.plist
        }
        """
        XCTAssertNil(PendingNetEngineRestart.parsePID(launchctlPrintOutput: stopped))
        XCTAssertNil(PendingNetEngineRestart.parsePID(launchctlPrintOutput: ""))
    }

    /// `launchctl print` 找不到 job 时输出的是错误文案，别从里面认出一个假 pid。
    func testGarbageNeverYieldsAPID() {
        XCTAssertNil(PendingNetEngineRestart.parsePID(
            launchctlPrintOutput: "Could not find service \"io.sbtally.singbox\""))
        XCTAssertNil(PendingNetEngineRestart.parsePID(launchctlPrintOutput: "\tpid = \n"))
        XCTAssertNil(PendingNetEngineRestart.parsePID(launchctlPrintOutput: "\tpid = none\n"))
    }

    /// 认的是 job 自己那条，不是子字典里后面某条。
    func testTakesTheJobsOwnPIDNotALaterOne() {
        let withNested = printOutput.replacingOccurrences(
            of: "\t\t\tstate = active", with: "\t\t\tpid = 999")
        XCTAssertEqual(PendingNetEngineRestart.parsePID(launchctlPrintOutput: withNested), 588)
    }

    /// Repeated clicks can enqueue another start after the first one already
    /// succeeded. That second request must reuse the live engine instead of
    /// booting it out and rebuilding the TUN again.
    func testStartIsIdempotentOnceTheEngineIsRunning() {
        XCTAssertEqual(
            PendingNetEngineLifecycle.startAction(engineRunning: true),
            .reuseRunningEngine
        )
        XCTAssertEqual(
            PendingNetEngineLifecycle.startAction(engineRunning: false),
            .launchEngine
        )
    }

    /// A second stop arriving after the first one finished is success, not a
    /// launchctl error and another DNS flush.
    func testStopIsIdempotentOnceTheEngineHasExited() {
        XCTAssertEqual(PendingNetEngineLifecycle.stopAction(enginePID: nil), .alreadyStopped)
        XCTAssertEqual(PendingNetEngineLifecycle.stopAction(enginePID: 588), .stopEngine(588))
    }

    /// A delayed link-change recovery must not resurrect an engine after a
    /// user stop won the serialized-operation race.
    func testSelfHealRechecksThatTheEngineStillShouldRun() {
        XCTAssertTrue(PendingNetEngineLifecycle.shouldRunSelfHeal(engineRunning: true))
        XCTAssertFalse(PendingNetEngineLifecycle.shouldRunSelfHeal(engineRunning: false))
    }
}

final class PendingNetLocalEngineResidueTests: XCTestCase {
    /// `lsof -t` 一行一个 PID；同一个进程可能因为多条匹配记录重复出现。
    func testParsesUniqueListenerPIDs() {
        XCTAssertEqual(
            PendingNetLocalEngineResidue.parseListenerPIDs("54131\n54131\n60002\n"),
            [54131, 60002]
        )
    }

    /// 空行、诊断文字和不合法的 PID 都不能变成待终止进程。
    func testIgnoresMalformedListenerOutput() {
        XCTAssertEqual(
            PendingNetLocalEngineResidue.parseListenerPIDs(
                "lsof: unacceptable port specification\n0\n-1\nabc\n42\n"
            ),
            [42]
        )
    }

    func testOnlyAcceptsTheExactAppOwnedCommand() {
        let binary = "/Applications/PendingNet.app/Contents/MacOS/sing-box"
        let config = "/Users/test/Library/Application Support/PendingNet/engine/config.json"
        let expected = "\(binary) run -c \(config)"

        XCTAssertTrue(PendingNetLocalEngineResidue.isOwnedCommand(
            expected + "\n", binaryPath: binary, configPath: config))
        XCTAssertFalse(PendingNetLocalEngineResidue.isOwnedCommand(
            "\(binary) run -c /tmp/other.json", binaryPath: binary, configPath: config))
        XCTAssertFalse(PendingNetLocalEngineResidue.isOwnedCommand(
            "/usr/local/bin/sing-box run -c \(config)",
            binaryPath: binary,
            configPath: config
        ))
    }
}
