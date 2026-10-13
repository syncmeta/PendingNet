import XCTest
@testable import SBTallyCore

final class PendingNetHelperRecoveryTests: XCTestCase {
    @MainActor
    func testConcurrentPollsPerformOnlyOneRegistrationMigration() async {
        let recovery = PendingNetHelperRecovery()
        var calls = 0
        let first = Task { await recovery.run { calls += 1; try? await Task.sleep(for: .milliseconds(30)); return true } }
        await Task.yield()
        let second = Task { await recovery.run { calls += 1; return false } }
        let results = await (first.value, second.value)
        XCTAssertTrue(results.0); XCTAssertTrue(results.1); XCTAssertEqual(calls, 1)
    }
    @MainActor
    func testFailedProbeDoesNotPoisonFutureRecovery() async {
        let recovery = PendingNetHelperRecovery()
        let first = await recovery.run { false }
        let second = await recovery.run { true }
        XCTAssertFalse(first); XCTAssertTrue(second)
    }
    func testOldConnectionInvalidationLeavesReplacementAlive() {
        var state = PendingNetHelperConnectionState()
        let old = state.attach(); let replacement = state.attach()
        XCTAssertFalse(state.invalidate(old))
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertTrue(state.invalidate(replacement))
        XCTAssertNil(state.current)
    }
    @MainActor
    func testUnresponsiveCleanupCannotBlockExitOrReplyTwice() {
        let gate = PendingNetTerminationGate()
        // Deadline wins while helper cleanup has still not answered.
        XCTAssertTrue(gate.finish())
        // A late failure must not cancel quitting or produce another reply.
        XCTAssertFalse(gate.finish())
    }
}
