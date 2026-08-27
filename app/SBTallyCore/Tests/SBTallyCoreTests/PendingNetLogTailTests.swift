import XCTest
@testable import SBTallyCore

final class PendingNetLogTailTests: XCTestCase {
    func testSmallLogIsReadWholeAndANSICodesAreRemoved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-log-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("plain\n\u{001B}[31mERROR\u{001B}[0m detail\n".utf8).write(to: url)

        XCTAssertEqual(
            try PendingNetLogTail.read(path: url.path),
            "plain\nERROR detail\n"
        )
    }

    func testLargeLogReadsOnlyBoundedTailAndDropsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-log-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("discard-this-line\nkeep-one\nkeep-two\n".utf8).write(to: url)

        XCTAssertEqual(
            try PendingNetLogTail.read(path: url.path, maximumBytes: 23),
            "keep-one\nkeep-two\n"
        )
    }

    func testNonPositiveLimitReturnsEmptyWithoutOpeningFile() throws {
        XCTAssertEqual(
            try PendingNetLogTail.read(path: "/does/not/exist", maximumBytes: 0),
            ""
        )
    }
}
