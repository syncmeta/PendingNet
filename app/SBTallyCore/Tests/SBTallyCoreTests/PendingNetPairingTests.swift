import XCTest
@testable import SBTallyCore

final class PendingNetPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func pairingJSON(expiresAt: String = "2026-05-01T00:00:00Z") -> Data {
        Data("""
        {
          "format": "pendingnet-pairing",
          "version": 1,
          "server_id": "pns_test",
          "name": "VPS Test",
          "control": {
            "endpoint": "https://203.0.113.10:7443",
            "certificate_sha256": "sha256:abababababababababababababababababababababababababababababababab"
          },
          "enrollment": {
            "token": "ttttttttttttttttttttttttttttttttttttttttttt",
            "expires_at": "\(expiresAt)"
          }
        }
        """.utf8)
    }

    func testDecodePairingFile() throws {
        let pairing = try PendingNetPairingFile.decode(pairingJSON(), now: now)
        XCTAssertEqual(pairing.serverID, "pns_test")
        XCTAssertEqual(pairing.name, "VPS Test")
        XCTAssertEqual(pairing.control.endpoint, "https://203.0.113.10:7443")
    }

    func testRejectsExpiredPairingFile() {
        XCTAssertThrowsError(try PendingNetPairingFile.decode(
            pairingJSON(expiresAt: "2025-01-01T00:00:00Z"), now: now
        )) { error in
            XCTAssertEqual(error as? PendingNetPairingError, .expired)
        }
    }

    func testRejectsUnknownPairingFields() {
        var object = try! JSONSerialization.jsonObject(with: pairingJSON()) as! [String: Any]
        object["proxy_config"] = ["type": "vless"]
        let data = try! JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try PendingNetPairingFile.decode(data, now: now)) { error in
            XCTAssertEqual(error as? PendingNetPairingError, .unexpectedFields)
        }
    }

    func testEnrollRequestAndResponse() async throws {
        let pairing = try PendingNetPairingFile.decode(pairingJSON(), now: now)
        PairingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/enroll")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["device_name"], "Test iPhone")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "device_id":"dev_1",
              "access_token":"device-secret",
              "server":{"api_version":1,"server_id":"pns_test","name":"VPS Test","capabilities":["pairing-v1"]}
            }
            """.utf8)
            return (response, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let result = try await PendingNetEnrollmentClient(session: session)
            .enroll(pairing: pairing, deviceName: "Test iPhone", now: now)
        XCTAssertEqual(result.deviceID, "dev_1")
        XCTAssertEqual(result.server.serverID, pairing.serverID)
    }

    func testAuthenticatedNodeProfileRequest() async throws {
        PairingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/node")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-secret")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "version":1,
              "server_id":"pns_test",
              "updated_at":"2026-07-31T12:00:00.123456Z",
              "protocols":[
                {
                  "id":"reality","type":"vless-reality","display_name":"Reality",
                  "vless_reality":{
                    "server":"203.0.113.10","server_port":443,
                    "uuid":"11111111-1111-1111-1111-111111111111",
                    "flow":"xtls-rprx-vision","server_name":"www.microsoft.com",
                    "public_key":"public-key","short_id":"abcdef12"
                  }
                }
              ]
            }
            """.utf8)
            return (response, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profile = try await PendingNetServerClient(
            endpoint: "https://203.0.113.10:7443",
            certificateSHA256: "sha256:" + String(repeating: "ab", count: 32),
            accessToken: "device-secret",
            session: session
        ).nodeProfile()
        XCTAssertEqual(profile.serverID, "pns_test")
        XCTAssertEqual(profile.protocols.first?.type, "vless-reality")
        XCTAssertEqual(profile.protocols.first?.vlessReality?.serverPort, 443)
    }

    func testLivePendingNetServerWhenPairingFileIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["PENDINGNET_LIVE_PAIRING_FILE"] else {
            throw XCTSkip("PENDINGNET_LIVE_PAIRING_FILE is not set")
        }
        let pairing = try PendingNetPairingFile.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let enrolled = try await PendingNetEnrollmentClient().enroll(
            pairing: pairing,
            deviceName: "PendingNet integration test"
        )
        let profile = try await PendingNetServerClient(
            endpoint: pairing.control.endpoint,
            certificateSHA256: pairing.control.certificateSHA256,
            accessToken: enrolled.accessToken
        ).nodeProfile()
        XCTAssertEqual(profile.serverID, pairing.serverID)
        XCTAssertEqual(Set(profile.protocols.map(\.type)), ["vless-reality", "hysteria2"])
        let outbounds = try profile.singBoxProxyOutbounds(tagPrefix: "live-vps")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: outbounds) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 2)
        if let singBox = ProcessInfo.processInfo.environment["PENDINGNET_LIVE_SING_BOX"] {
            for (index, outbound) in decoded.enumerated() {
                try await smokeProxyOutbound(outbound, singBox: singBox, port: 21991 + index)
            }
            if let configDirectory = ProcessInfo.processInfo.environment["PENDINGNET_LIVE_LOCAL_CONFIG_DIR"] {
                try validateMergedLocalConfigs(
                    profile: profile,
                    name: pairing.name,
                    configDirectory: configDirectory,
                    singBox: singBox
                )
            }
        }
    }
}

private func validateMergedLocalConfigs(
    profile: PendingNetNodeProfile,
    name: String,
    configDirectory: String,
    singBox: String
) throws {
    let runtime = try profile.runtimeServer(name: name)
    for filename in ["master-tun.json", "master-notun.json"] {
        let source = URL(fileURLWithPath: configDirectory).appendingPathComponent(filename)
        let merged = try PendingNetLocalConfigComposer.merge(
            baseConfig: Data(contentsOf: source), runtimeServer: runtime)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-merged-\(UUID().uuidString)-\(filename)")
        try merged.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try checkSingBoxConfig(temporary, singBox: singBox)
    }
}

private func checkSingBoxConfig(_ configURL: URL, singBox: String) throws {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: singBox)
    check.arguments = ["check", "-c", configURL.path]
    let checkLog = Pipe()
    check.standardOutput = checkLog
    check.standardError = checkLog
    try check.run()
    let checkData = checkLog.fileHandleForReading.readDataToEndOfFile()
    check.waitUntilExit()
    XCTAssertEqual(check.terminationStatus, 0, String(decoding: checkData, as: UTF8.self))
}

private func smokeProxyOutbound(
    _ outbound: [String: Any],
    singBox: String,
    port: Int
) async throws {
    let tag = try XCTUnwrap(outbound["tag"] as? String)
    let config: [String: Any] = [
        "log": ["level": "warn"],
        "inbounds": [[
            "type": "mixed", "tag": "smoke-in", "listen": "127.0.0.1", "listen_port": port,
        ]],
        "outbounds": [outbound],
        "route": ["final": tag, "auto_detect_interface": true],
    ]
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pendingnet-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        .write(to: configURL, options: .atomic)

    try checkSingBoxConfig(configURL, singBox: singBox)

    let engine = Process()
    engine.executableURL = URL(fileURLWithPath: singBox)
    engine.arguments = ["run", "-c", configURL.path]
    engine.standardOutput = FileHandle.nullDevice
    engine.standardError = FileHandle.nullDevice
    try engine.run()
    defer {
        if engine.isRunning { engine.terminate() }
        engine.waitUntilExit()
    }
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertTrue(engine.isRunning, "sing-box exited before \(tag) smoke request")

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = [
        "-fsS", "--max-time", "15", "--proxy", "socks5h://127.0.0.1:\(port)",
        "https://www.cloudflare.com/cdn-cgi/trace",
    ]
    let response = Pipe()
    curl.standardOutput = response
    curl.standardError = response
    try curl.run()
    let responseData = response.fileHandleForReading.readDataToEndOfFile()
    curl.waitUntilExit()
    XCTAssertEqual(curl.terminationStatus, 0, "\(tag): \(String(decoding: responseData, as: UTF8.self))")
    XCTAssertTrue(String(decoding: responseData, as: UTF8.self).contains("ip="), "\(tag) returned an unexpected response")
}

private func requestBody(_ request: URLRequest) throws -> Data {
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

private final class PairingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
