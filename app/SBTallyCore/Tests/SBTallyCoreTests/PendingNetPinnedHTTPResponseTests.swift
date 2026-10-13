import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetPinnedHTTPResponseTests: XCTestCase {
    func testChunkedManagementBodyIsDecodedBeforeJSON() throws {
        let body = Data("{\"users\":[]}".utf8)
        let wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5;extension=value\r\n{\"use\r\n7\r\nrs\":[]}\r\n0\r\nX-End: yes\r\n\r\n".utf8)
        let response = try PendingNetPinnedHTTPClient.parseResponse(wire)
        XCTAssertEqual(response.body, body)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: response.body))
    }
    func testRejectsTruncatedOrAmbiguousFraming() {
        for raw in [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabc\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        ] { XCTAssertThrowsError(try PendingNetPinnedHTTPClient.parseResponse(Data(raw.utf8))) }
    }
    func testContentLengthAndCloseDelimitedBodies() throws {
        for headers in ["Content-Length: 2\r\n", "Connection: close\r\n"] {
            let raw = Data("HTTP/1.1 200 OK\r\n\(headers)\r\n{}".utf8)
            XCTAssertEqual(try PendingNetPinnedHTTPClient.parseResponse(raw).body, Data("{}".utf8))
        }
    }
}
