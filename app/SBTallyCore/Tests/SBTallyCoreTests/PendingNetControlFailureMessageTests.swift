import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetControlFailureMessageTests: XCTestCase {
    func testConnectionRefusedDoesNotExposeNSErrorDump() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]
        )

        let text = PendingNetControlFailureMessage.text(for: error)

        XCTAssertEqual(text, "代理引擎没有响应，请先打开连接；若已经连接，请重新连接后再试。")
        XCTAssertFalse(text.contains("Error Domain"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }

    func testMissingControlSecretHasSpecificRecovery() {
        let error = URLError(.userAuthenticationRequired)
        XCTAssertEqual(
            PendingNetControlFailureMessage.text(for: error),
            "找不到代理控制凭据，请重新连接后再试。"
        )
    }

    func testUnknownFailureStaysShortAndActionable() {
        let error = NSError(domain: "test", code: 7, userInfo: [
            NSLocalizedDescriptionKey: String(repeating: "technical details ", count: 50),
        ])
        XCTAssertEqual(
            PendingNetControlFailureMessage.text(for: error),
            "代理控制失败，请重新连接后再试。"
        )
    }
}
