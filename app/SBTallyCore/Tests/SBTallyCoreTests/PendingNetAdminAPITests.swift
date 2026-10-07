import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetAdminAPITests: XCTestCase {
    private func server() -> PendingNetManagedServer {
        PendingNetManagedServer(
            serverID: "pns_admin_test", name: "Test Server",
            endpoint: "https://203.0.113.10:7443",
            certificateSHA256: "sha256:" + String(repeating: "ab", count: 32),
            deviceID: "dev_admin"
        )
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdminAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testReadsUsersWithOnlyAdminCredential() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        try admin.save(accessToken: "admin-secret", serverID: "pns_admin_test")
        let ordinary = PendingNetCredentialStoreCore(
            service: PendingNetCredentialStore.service,
            locations: PendingNetCredentialStore.locations,
            backend: backend
        )
        try ordinary.save(accessToken: "connection-secret", serverID: "pns_admin_test")

        AdminAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/admin/users")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-secret")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("""
            {"users":[{"id":"usr_1","name":"Visitor 1","role":"client",\
            "created_at":"2026-09-27T12:00:00Z",\
            "login_ips":[{"ip":"203.0.113.20","first_seen_at":"2026-09-27T12:01:00Z"}]}]}
            """.utf8))
        }
        let users = try await PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session())
            .users()
        XCTAssertEqual(users.map(\.name), ["Visitor 1"])
        XCTAssertEqual(users.first?.loginIPs?.first?.ip, "203.0.113.20")
        XCTAssertEqual(try ordinary.load(serverID: "pns_admin_test"), "connection-secret")
    }

    func testMissingAdminCredentialDoesNotFallBackToConnectionToken() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        let ordinary = PendingNetCredentialStoreCore(
            service: PendingNetCredentialStore.service,
            locations: PendingNetCredentialStore.locations,
            backend: backend
        )
        try ordinary.save(accessToken: "connection-secret", serverID: "pns_admin_test")
        AdminAPIURLProtocol.handler = { _ in
            XCTFail("No request may be sent without the admin credential")
            throw PendingNetPairingError.invalidServerResponse
        }
        do {
            _ = try await PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session()).users()
            XCTFail("expected missing admin credential")
        } catch let error as PendingNetAdminAPIError {
            XCTAssertEqual(error, .missingCredential)
        }
    }

    func testReadsConfigSnapshotAndRejectsUnauthorizedResponse() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        try admin.save(accessToken: "admin-secret", serverID: "pns_admin_test")
        AdminAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/admin/config")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("""
            {"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\
            "node":{"version":1},"xray":{"inbounds":[]},"hysteria":{"listen":":443"}}
            """.utf8))
        }
        let client = PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session())
        let snapshot = try await client.config()
        XCTAssertEqual(snapshot.revision.count, 64)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: snapshot.node) as? [String: Any])

        AdminAPIURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"error\":\"forbidden\",\"message\":\"management permission required\"}".utf8))
        }
        do {
            _ = try await client.users()
            XCTFail("expected forbidden")
        } catch let error as PendingNetAdminAPIError {
            XCTAssertEqual(error, .rejected(statusCode: 403))
        }
    }

    func testRevokeUsesAdminCredentialAndRejectsUnsafeUserID() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        try admin.save(accessToken: "admin-secret", serverID: "pns_admin_test")
        AdminAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/admin/users/usr_1/revoke")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-secret")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session())
        try await client.revokeUser(id: "usr_1")
        do {
            try await client.revokeUser(id: "../config")
            XCTFail("expected invalid ID")
        } catch let error as PendingNetAdminAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPairingIssueRequiresExplicitRoleAndValidatesReturnedLink() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        try admin.save(accessToken: "admin-secret", serverID: "pns_admin_test")
        let json = Data("""
        {"format":"pendingnet-pairing","version":1,"server_id":"pns_admin_test",\
        "name":"Test Server","control":{"endpoint":"https://203.0.113.10:7443",\
        "certificate_sha256":"sha256:\(String(repeating: "ab", count: 32))"},\
        "enrollment":{"token":"\(String(repeating: "t", count: 40))",\
        "expires_at":"2099-01-01T00:00:00Z","role":"admin"}}
        """.utf8)
        let link = "pendingnet://pair?v=1&d=" + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        AdminAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/admin/pairings")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-secret")
            let body = try adminRequestBody(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["role"] as? String, "admin")
            XCTAssertEqual(payload["ttl_seconds"] as? Int, 600)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: ["link": link, "expires_at": "2099-01-01T00:00:00Z"]))
        }
        let client = PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session())
        let issued = try await client.issuePairing(role: .admin, ttlSeconds: 600)
        XCTAssertEqual(issued.link, link)

        AdminAPIURLProtocol.handler = { request in
            let body = try adminRequestBody(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["role"] as? String, "client")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: ["link": link, "expires_at": "2099-01-01T00:00:00Z"]))
        }
        do {
            _ = try await client.issuePairing(role: .client, ttlSeconds: 600)
            XCTFail("expected role mismatch")
        } catch let error as PendingNetAdminAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testClientConfigExportUsesOnlyAdminCredentialAndRejectsMalformedBody() async throws {
        let backend = FakeKeychain()
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)
        try admin.save(accessToken: "admin-secret", serverID: "pns_admin_test")
        AdminAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/admin/client-config")
            XCTAssertEqual(request.url?.query, "platform=android")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-secret")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("""
            {"inbounds":[{"type":"tun"}],"outbounds":[{"type":"vless","uuid":"secret"}],"route":{"final":"proxy"}}
            """.utf8))
        }
        let client = PendingNetAdminAPIClient(server: server(), credentialStore: admin, session: session())
        let data = try await client.clientConfig(platform: .android)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        AdminAPIURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        do {
            _ = try await client.clientConfig(platform: .windows)
            XCTFail("expected malformed config rejection")
        } catch let error as PendingNetAdminAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }
}

private func adminRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class AdminAPIURLProtocol: URLProtocol {
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
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
