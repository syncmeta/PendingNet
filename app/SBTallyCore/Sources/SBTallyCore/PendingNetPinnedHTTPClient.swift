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
                    guard stateBox.received.count <= 8 * (1 << 20) else {
                        finish(.failure(PendingNetPairingError.invalidServerResponse)); return
                    }
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

    static func parseResponse(_ data: Data) throws -> PendingNetPinnedHTTPResponse {
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
        guard split.lowerBound <= 64 * 1024, (100...599).contains(statusCode) else {
            throw PendingNetPairingError.invalidServerResponse
        }
        var headers: [String: [String]] = [:]
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw PendingNetPairingError.invalidServerResponse }
            let name = line[..<colon].lowercased()
            headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let rawBody = Data(data[split.upperBound...])
        let body: Data
        if let encoding = headers["transfer-encoding"] {
            guard encoding.count == 1, encoding[0].lowercased() == "chunked", headers["content-length"] == nil else {
                throw PendingNetPairingError.invalidServerResponse
            }
            body = try decodeChunks(rawBody)
        } else if let lengths = headers["content-length"] {
            guard lengths.count == 1, lengths[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int(lengths[0]), length == rawBody.count else {
                throw PendingNetPairingError.invalidServerResponse
            }
            body = rawBody
        } else { body = rawBody }
        return PendingNetPinnedHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var cursor = data.startIndex
        var result = Data()
        while cursor < data.endIndex {
            guard let end = data.range(of: crlf, in: cursor..<data.endIndex),
                  end.lowerBound - cursor <= 1024,
                  let line = String(data: data[cursor..<end.lowerBound], encoding: .ascii),
                  let sizeWord = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                  !sizeWord.isEmpty, sizeWord.allSatisfy({ $0.isHexDigit }),
                  let size = Int(sizeWord, radix: 16), size <= 4 * (1 << 20) - result.count else {
                throw PendingNetPairingError.invalidServerResponse
            }
            cursor = end.upperBound
            if size == 0 {
                // Consume trailers and the final empty line; don't pass framing to JSON.
                while let trailerEnd = data.range(of: crlf, in: cursor..<data.endIndex) {
                    let trailer = data[cursor..<trailerEnd.lowerBound]
                    cursor = trailerEnd.upperBound
                    if trailer.isEmpty {
                        guard cursor == data.endIndex else { throw PendingNetPairingError.invalidServerResponse }
                        return result
                    }
                    guard trailer.contains(58) else { throw PendingNetPairingError.invalidServerResponse }
                }
                throw PendingNetPairingError.invalidServerResponse
            }
            guard size <= data.endIndex - cursor, data.endIndex - cursor - size >= 2 else {
                throw PendingNetPairingError.invalidServerResponse
            }
            result.append(data[cursor..<cursor + size]); cursor += size
            guard data[cursor..<cursor + 2] == crlf else { throw PendingNetPairingError.invalidServerResponse }
            cursor += 2
        }
        throw PendingNetPairingError.invalidServerResponse
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
