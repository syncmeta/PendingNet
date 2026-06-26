import XCTest
import SBTallyCore

final class StubURLProtocol: URLProtocol {
    static var body = Data()
    static var lastURL: URL?
    static var lastMethod: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        Self.lastMethod = request.httpMethod
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIStatsProviderTests: XCTestCase {
    private func provider() -> APIStatsProvider {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!,
                                session: URLSession(configuration: cfg))
    }

    func testApps() async throws {
        StubURLProtocol.body = Data(#"[{"app":"Safari","upload":1,"download":2,"total":3}]"#.utf8)
        let apps = try await provider().apps(since: "24h", top: 20)
        XCTAssertEqual(apps.first?.app, "Safari")
        XCTAssertEqual(StubURLProtocol.lastURL?.path, "/api/apps")
    }

    func testSummary() async throws {
        StubURLProtocol.body = Data(#"{"since":0,"upload":10,"download":5,"total":15,"apps":2,"hosts":3}"#.utf8)
        let s = try await provider().summary(since: "24h")
        XCTAssertEqual(s.total, 15)
    }

    func testAppDetailEncodesSpaces() async throws {
        StubURLProtocol.body = Data(#"{"app":"Google Chrome","domains":[]}"#.utf8)
        let d = try await provider().appDetail("Google Chrome", since: "24h")
        XCTAssertEqual(d.app, "Google Chrome")
        XCTAssertEqual(StubURLProtocol.lastURL?.absoluteString.contains("Google%20Chrome"), true)
    }

    func testControlState() async throws {
        StubURLProtocol.body = Data(#"{"mode":"Rule","proxies":{"proxy":{"type":"Selector","now":"vpsA","all":["vpsA","vpsB"]}}}"#.utf8)
        let s = try await provider().controlState()
        XCTAssertEqual(s.mode, "Rule")
        XCTAssertEqual(s.proxies["proxy"]?.now, "vpsA")
        XCTAssertEqual(s.proxies["proxy"]?.all?.count, 2)
        XCTAssertEqual(StubURLProtocol.lastURL?.path, "/api/control/state")
    }

    func testSelectPostsToEndpoint() async throws {
        StubURLProtocol.body = Data()
        try await provider().select(selector: "proxy", name: "vpsB")
        XCTAssertEqual(StubURLProtocol.lastMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastURL?.path, "/api/control/select")
    }

    func testSetModePostsToEndpoint() async throws {
        StubURLProtocol.body = Data()
        try await provider().setMode("Global")
        XCTAssertEqual(StubURLProtocol.lastMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastURL?.path, "/api/control/mode")
    }
}
