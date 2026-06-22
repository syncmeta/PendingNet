import XCTest
import SBTallyCore

final class ModelsTests: XCTestCase {
    func testDecodeAppStats() throws {
        let json = #"[{"app":"Safari","upload":100,"download":200,"total":300}]"#.data(using: .utf8)!
        let apps = try JSONDecoder().decode([AppStat].self, from: json)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].app, "Safari")
        XCTAssertEqual(apps[0].total, 300)
    }

    func testDecodeEmptyArray() throws {
        let apps = try JSONDecoder().decode([AppStat].self, from: Data("[]".utf8))
        XCTAssertTrue(apps.isEmpty)
    }

    func testDecodeLiveGroup() throws {
        let json = #"{"app":"X","upRate":10,"downRate":2,"conns":3,"topHost":"a.com"}"#.data(using: .utf8)!
        let g = try JSONDecoder().decode(LiveAppGroup.self, from: json)
        XCTAssertEqual(g.upRate, 10)
        XCTAssertEqual(g.topHost, "a.com")
    }

    func testDecodeAppDetail() throws {
        let json = #"{"app":"Mail","domains":[{"host":"c.com","upload":1,"download":2,"total":3}]}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(AppDetail.self, from: json)
        XCTAssertEqual(d.domains.first?.host, "c.com")
    }
}
