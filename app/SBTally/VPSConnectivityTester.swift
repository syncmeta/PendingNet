import Foundation
import Network
import SBTallyCore
import os

/// Probes whether a paired VPS is actually reachable.
///
/// Two ladders, best first:
/// 1. If the engine is running and the VPS is the one currently applied, ask
///    sing-box to time a real request through that outbound (clash-api delay) —
///    this is end-to-end truth, not just "the box answers pings".
/// 2. Otherwise open a plain TCP connection to the VPS control endpoint. That
///    only proves the host is reachable, so the UI says so.
@MainActor
final class VPSConnectivityTester: ObservableObject {
    enum Outcome: Equatable {
        case testing
        case reachable(milliseconds: Int, detail: String)
        case failed(String)
    }

    @Published private(set) var results: [String: Outcome] = [:]

    func isTesting(_ serverID: String) -> Bool { results[serverID] == .testing }

    var busy: Bool { results.values.contains(.testing) }

    func test(_ server: PairedVPSServer, throughProxyTag proxyTag: String?) async {
        results[server.serverID] = .testing
        if let proxyTag {
            do {
                let delay = try await Self.engineDelay(proxyTag: proxyTag)
                results[server.serverID] = .reachable(milliseconds: delay, detail: "经代理实测")
                return
            } catch {
                // Engine path unavailable (not running, or the outbound cannot
                // reach the internet). Fall through to the raw TCP probe so the
                // user still learns whether the VPS itself is up.
                if let message = Self.engineDelayFailureMessage(error) {
                    results[server.serverID] = .failed(message)
                    return
                }
            }
        }
        do {
            let elapsed = try await Self.tcpProbe(endpoint: server.endpoint)
            results[server.serverID] = .reachable(milliseconds: elapsed, detail: "VPS 可达（未经代理）")
        } catch {
            results[server.serverID] = .failed(Self.humanMessage(error))
        }
    }

    // MARK: - Engine (clash-api) delay

    private static func engineDelay(proxyTag: String) async throws -> Int {
        var components = URLComponents(
            url: PendingNetUserEngine.controlURL.appendingPathComponent("proxies")
                .appendingPathComponent(proxyTag)
                .appendingPathComponent("delay"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "timeout", value: "5000"),
            URLQueryItem(name: "url", value: "http://cp.cloudflare.com/generate_204"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(try controlSecret())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 200,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let delay = object["delay"] as? Int {
            return delay
        }
        // sing-box answers a failed probe with a message body — surface it.
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        throw EngineDelayError(message: object?["message"] as? String, statusCode: http.statusCode)
    }

    private struct EngineDelayError: Error {
        let message: String?
        let statusCode: Int
    }

    /// A definite verdict from the engine ("the proxy cannot reach the internet")
    /// is worth showing; anything that just means "engine not usable" returns nil
    /// so the caller falls back to the TCP probe.
    private static func engineDelayFailureMessage(_ error: Error) -> String? {
        guard let delayError = error as? EngineDelayError else { return nil }
        guard delayError.statusCode != 404 else { return nil }
        let raw = delayError.message?.lowercased() ?? ""
        if raw.contains("timeout") || raw.contains("deadline") {
            return "不通：经这台 VPS 请求超时，节点可能被封或已下线"
        }
        if raw.contains("refused") {
            return "不通：VPS 上的节点端口拒绝连接"
        }
        if raw.isEmpty { return nil }
        return "不通：\(delayError.message ?? "")"
    }

    private static func controlSecret() throws -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("PendingNet/engine/control-secret")
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw URLError(.userAuthenticationRequired) }
        return value
    }

    // MARK: - Raw TCP probe

    private struct ProbeError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private static func tcpProbe(endpoint: String) async throws -> Int {
        guard let components = URLComponents(string: endpoint),
              let host = components.host,
              let rawPort = UInt16(exactly: components.port ?? 443),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw ProbeError(text: "这台 VPS 的地址无法解析，请重新导入 .pdn")
        }
        let started = DispatchTime.now()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        let queue = DispatchQueue(label: "com.pendingname.pendingnet.probe.\(UUID().uuidString)")

        return try await withCheckedThrowingContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            func settle(_ result: Result<Int, Error>) {
                let alreadyDone = finished.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    settle(.success(Int(elapsed)))
                case .failed(let error):
                    settle(.failure(error))
                case .waiting(let error):
                    // .waiting means the path is not usable right now (refused,
                    // no route). Treat it as a failure instead of hanging.
                    settle(.failure(error))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 6) {
                settle(.failure(ProbeError(text: "连接超时：这台 VPS 在 6 秒内没有回应")))
            }
            connection.start(queue: queue)
        }
    }

    private static func humanMessage(_ error: Error) -> String {
        if let probe = error as? ProbeError { return "不通：\(probe.text)" }
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED: return "不通：连接被拒绝，VPS 上的服务没在监听这个端口"
                case .ETIMEDOUT: return "不通：连接超时，可能被防火墙拦截"
                case .EHOSTUNREACH, .ENETUNREACH: return "不通：网络到不了这台 VPS，请检查本机网络"
                default: return "不通：\(nwError.localizedDescription)"
                }
            case .dns:
                return "不通：域名解析失败，请检查 VPS 地址和本机 DNS"
            default:
                return "不通：\(nwError.localizedDescription)"
            }
        }
        return "不通：\(error.localizedDescription)"
    }
}
