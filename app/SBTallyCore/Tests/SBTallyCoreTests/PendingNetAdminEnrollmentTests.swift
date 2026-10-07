import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetAdminEnrollmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func link(role: String?) throws -> String {
        var enrollment: [String: Any] = [
            "token": String(repeating: "t", count: 40),
            "expires_at": "2027-02-01T00:00:00Z",
        ]
        if let role { enrollment["role"] = role }
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "pendingnet-pairing",
            "version": 1,
            "server_id": "pns_admin_test",
            "name": "Test Server",
            "control": [
                "endpoint": "https://203.0.113.10:7443",
                "certificate_sha256": "sha256:" + String(repeating: "ab", count: 32),
            ],
            "enrollment": enrollment,
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "pendingnet://pair?v=1&d=" + payload
    }

    func testAdminEnrollmentStoresOnlySeparateManagementCredential() async throws {
        let backend = FakeKeychain()
        let ordinary = PendingNetCredentialStoreCore(
            service: PendingNetCredentialStore.service,
            locations: PendingNetCredentialStore.locations,
            backend: backend
        )
        try ordinary.save(accessToken: "connection-token", serverID: "pns_admin_test")
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)

        AdminEnrollmentURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/enroll")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data("""
            {"device_id":"dev_admin","access_token":"admin-token","role":"admin",\
            "server":{"api_version":1,"server_id":"pns_admin_test","name":"Test Server","capabilities":[]}}
            """.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdminEnrollmentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let result = try await PendingNetAdminEnrollmentClient(session: session, credentialStore: admin)
            .enroll(link: link(role: "admin"), deviceName: "Test Mac", now: now)

        XCTAssertEqual(result.serverID, "pns_admin_test")
        XCTAssertEqual(result.endpoint, "https://203.0.113.10:7443")
        XCTAssertEqual(try admin.load(serverID: "pns_admin_test"), "admin-token")
        XCTAssertEqual(try ordinary.load(serverID: "pns_admin_test"), "connection-token")
    }

    func testOrdinaryLinkCannotEnterManagementEnrollment() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdminEnrollmentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        do {
            try await PendingNetAdminEnrollmentClient(session: session, credentialStore: admin)
                .enroll(link: try self.link(role: nil), deviceName: "Test Mac", now: self.now)
            XCTFail("ordinary pairing link entered management enrollment")
        } catch let error as PendingNetAdminEnrollmentError {
            XCTAssertEqual(error, .notManagementLink)
        }
        XCTAssertNil(try admin.load(serverID: "pns_admin_test"))
    }
}

private final class AdminEnrollmentURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw PendingNetPairingError.invalidServerResponse }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
