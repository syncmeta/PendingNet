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
}
