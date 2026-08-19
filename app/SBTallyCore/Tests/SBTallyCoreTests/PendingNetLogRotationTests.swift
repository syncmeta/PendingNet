import XCTest
@testable import SBTallyCore

final class PendingNetLogRotationTests: XCTestCase {
    func testUnderLimitIsLeftAlone() {
        XCTAssertEqual(PendingNetLogRotation.plan(size: 0), .keep)
        XCTAssertEqual(
            PendingNetLogRotation.plan(size: PendingNetLogRotation.defaultSizeLimit), .keep)
    }

    /// 本机那份 160MB 的日志：截断，并留 2MB 尾巴。
    func testOverLimitRotatesKeepingTail() {
        XCTAssertEqual(
            PendingNetLogRotation.plan(size: 159_797_221),
            .rotate(keepingLastBytes: PendingNetLogRotation.defaultKeepTail))
    }

    /// 刚过线的文件本身可能比要保留的尾巴还短，别越界读。
    func testKeepTailNeverExceedsFileSize() {
        XCTAssertEqual(
            PendingNetLogRotation.plan(size: 150, limit: 100, keepTail: 4096),
            .rotate(keepingLastBytes: 150))
    }

    func testArchivePath() {
        XCTAssertEqual(
            PendingNetLogRotation.archivePath(for: "/var/log/sbtally-singbox.log"),
            "/var/log/sbtally-singbox.log.1")
    }
}
