import XCTest
import SBTallyCore

final class SSEParserTests: XCTestCase {
    func testParsesDataLine() {
        let line = #"data: [{"app":"X","upRate":5,"downRate":1,"conns":2,"topHost":"h"}]"#
        let groups = SSEParser.parse(dataLine: line)
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?.first?.app, "X")
    }

    func testIgnoresNonDataLine() {
        XCTAssertNil(SSEParser.parse(dataLine: ": keepalive"))
        XCTAssertNil(SSEParser.parse(dataLine: ""))
    }
}
