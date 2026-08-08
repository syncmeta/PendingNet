import CryptoKit
import Foundation
import Network
import Security

struct PendingNetPinnedHTTPResponse: Sendable {
    var statusCode: Int
    var body: Data
}

final class PendingNetPinnedHTTPClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let expectedFingerprint: String

    init(endpoint: String, certificateSHA256: String) throws {
        guard let components = URLComponents(string: endpoint),
              components.scheme == "https",
              let host = components.host else {
            throw PendingNetPairingError.invalidEndpoint
        }
        let port = components.port ?? 443
        guard let networkPort = UInt16(exactly: port) else {
            throw PendingNetPairingError.invalidEndpoint
        }
        self.host = host
        self.port = networkPort
        expectedFingerprint = certificateSHA256.lowercased()
    }

    func request(
        path: String,
        method: String,
        authorization: String? = nil,
        body: Data? = nil
    ) async throws -> PendingNetPinnedHTTPResponse {
        let queue = DispatchQueue(label: "com.pendingname.pendingnet.control.\(UUID().uuidString)")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let expectedFingerprint = expectedFingerprint
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = certificates.first else {
                complete(false)
                return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            let actual = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
            complete(actual == expectedFingerprint)
        }, queue)

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PendingNetPairingError.invalidEndpoint
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        let requestData = makeRequest(path: path, method: method, authorization: authorization, body: body)

        return try await withCheckedThrowingContinuation { continuation in
            let completion = PendingNetRequestCompletion(continuation)
            let stateBox = PendingNetRequestState()

            func finish(_ result: Result<PendingNetPinnedHTTPResponse, Error>) {
                connection.cancel()
                completion.resume(result)
            }

            func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, error in
                    if let data { stateBox.received.append(data) }
                    if let error {
                        finish(.failure(PendingNetPairingError.transport(error.localizedDescription)))
                    } else if isComplete {
                        do { finish(.success(try Self.parseResponse(stateBox.received))) }
                        catch { finish(.failure(error)) }
                    } else {
                        receiveMore()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready where !stateBox.didSend:
                    stateBox.didSend = true
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(PendingNetPairingError.transport(error.localizedDescription)))
                        } else {
                            receiveMore()
                        }
                    })
                case .failed(let error):
                    finish(.failure(PendingNetPairingError.transport(error.localizedDescription)))
                case .waiting(let error):
                    finish(.failure(PendingNetPairingError.transport(error.localizedDescription)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        authorization: String?,
        body: Data?
    ) -> Data {
        let body = body ?? Data()
        var headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/json",
            "Connection: close",
            "Content-Length: \(body.count)",
        ]
        if !body.isEmpty { headers.append("Content-Type: application/json") }
        if let authorization { headers.append("Authorization: \(authorization)") }
        var request = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        request.append(body)
        return request
    }

    private static func parseResponse(_ data: Data) throws -> PendingNetPinnedHTTPResponse {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: delimiter),
              let header = String(data: data[..<split.lowerBound], encoding: .utf8),
              let statusLine = header.split(separator: "\r\n", maxSplits: 1).first else {
            throw PendingNetPairingError.invalidServerResponse
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw PendingNetPairingError.invalidServerResponse
        }
        return PendingNetPinnedHTTPResponse(
            statusCode: statusCode,
            body: Data(data[split.upperBound...])
        )
    }
}

private final class PendingNetRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<PendingNetPinnedHTTPResponse, Error>

    init(_ continuation: CheckedContinuation<PendingNetPinnedHTTPResponse, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<PendingNetPinnedHTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class PendingNetRequestState: @unchecked Sendable {
    var received = Data()
    var didSend = false
}
