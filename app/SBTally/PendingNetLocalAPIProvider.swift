import Foundation
import SBTallyCore

struct PendingNetLocalAPIProvider: StatsProvider, ControlProvider {
    private let stats = APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!)
    private let controlBaseURL = PendingNetUserEngine.controlURL

    func summary(since: String) async throws -> Summary { try await stats.summary(since: since) }
    func apps(since: String, top: Int) async throws -> [AppStat] { try await stats.apps(since: since, top: top) }
    func domains(since: String, top: Int) async throws -> [DomainStat] { try await stats.domains(since: since, top: top) }
    func appDetail(_ name: String, since: String) async throws -> AppDetail { try await stats.appDetail(name, since: since) }
    func series(name: String?, since: String) async throws -> [Point] { try await stats.series(name: name, since: since) }
    func live() -> AsyncStream<[LiveAppGroup]> { stats.live() }

    func controlState() async throws -> ControlState {
        async let configData = request(path: "configs", method: "GET")
        async let proxyData = request(path: "proxies", method: "GET")
        let config = try JSONSerialization.jsonObject(with: await configData) as? [String: Any]
        let proxyRoot = try JSONSerialization.jsonObject(with: await proxyData) as? [String: Any]
        guard let mode = config?["mode"] as? String,
              let proxies = proxyRoot?["proxies"] else { throw URLError(.cannotParseResponse) }
        let combined = try JSONSerialization.data(withJSONObject: [
            "mode": mode,
            "proxies": proxies,
            "modeList": config?["mode-list"] as? [String] ?? [],
        ])
        return try JSONDecoder().decode(ControlState.self, from: combined)
    }

    func select(selector: String, name: String) async throws {
        _ = try await request(
            path: "proxies/\(selector)",
            method: "PUT",
            body: ["name": name]
        )
    }

    func setMode(_ mode: String) async throws {
        _ = try await request(path: "configs", method: "PATCH", body: ["mode": mode])
    }

    private func request(
        path: String,
        method: String,
        body: [String: String]? = nil
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var url = controlBaseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try controlSecret())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private func controlSecret() throws -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("PendingNet/engine/control-secret")
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw URLError(.userAuthenticationRequired) }
        return value
    }
}
