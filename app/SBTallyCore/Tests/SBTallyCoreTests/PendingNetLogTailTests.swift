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

    func testSnapshotCapsShortLinesAndReportsOriginalFileSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-log-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = "one\ntwo\nthree\nfour"
        try Data(contents.utf8).write(to: url)

        let snapshot = try PendingNetLogTail.snapshot(
            path: url.path,
            maximumBytes: 1_024,
            maximumLines: 2
        )
        XCTAssertEqual(snapshot.lines, ["three", "four"])
        XCTAssertEqual(snapshot.fileSize, UInt64(contents.utf8.count))
        XCTAssertTrue(snapshot.isTruncated)
    }

    func testSnapshotByteLimitStillDropsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-log-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("discard-this-line\nkeep-one\nkeep-two\n".utf8).write(to: url)

        let snapshot = try PendingNetLogTail.snapshot(
            path: url.path,
            maximumBytes: 23,
            maximumLines: 100
        )
        XCTAssertEqual(snapshot.lines, ["keep-one", "keep-two", ""])
        XCTAssertTrue(snapshot.isTruncated)
    }
}
