import XCTest
import SBTallyCore

final class ByteFormatTests: XCTestCase {
    func testHumanBytes() {
        XCTAssertEqual(humanBytes(0), "0 B")
        XCTAssertEqual(humanBytes(512), "512 B")
        XCTAssertEqual(humanBytes(1024), "1.0 KiB")
        XCTAssertEqual(humanBytes(1_048_576), "1.0 MiB")
        XCTAssertEqual(humanBytes(1_073_741_824), "1.0 GiB")
    }
}
