import Foundation

public struct APIStatsProvider: StatsProvider, ControlProvider {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private func makeURL(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = path
        comps?.queryItems = query.isEmpty ? nil : query
        return comps?.url
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        guard let url = makeURL(path, query) else { throw URLError(.badURL) }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func summary(since: String) async throws -> Summary {
        try await get("/api/summary", [.init(name: "since", value: since)])
    }
    public func apps(since: String, top: Int) async throws -> [AppStat] {
        try await get("/api/apps", [.init(name: "since", value: since), .init(name: "top", value: String(top))])
    }
    public func domains(since: String, top: Int) async throws -> [DomainStat] {
        try await get("/api/domains", [.init(name: "since", value: since), .init(name: "top", value: String(top))])
    }
    public func appDetail(_ name: String, since: String) async throws -> AppDetail {
        try await get("/api/app/\(name)", [.init(name: "since", value: since)])
    }
    public func series(name: String?, since: String) async throws -> [Point] {
        var q = [URLQueryItem(name: "since", value: since)]
        if let name { q.append(.init(name: "name", value: name)) }
        return try await get("/api/series", q)
    }

    private func post(_ path: String, _ body: [String: String]) async throws {
        guard let url = makeURL(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    public func controlState() async throws -> ControlState {
        try await get("/api/control/state", [])
    }
    public func select(selector: String, name: String) async throws {
        try await post("/api/control/select", ["selector": selector, "name": name])
    }
    public func setMode(_ mode: String) async throws {
        try await post("/api/control/mode", ["mode": mode])
    }

    public func live() -> AsyncStream<[LiveAppGroup]> {
        AsyncStream { continuation in
            guard let url = makeURL("/api/live") else {
                continuation.finish(); return
            }
            let session = self.session
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.finish(); return
                    }
                    for try await line in bytes.lines {
                        if let groups = SSEParser.parse(dataLine: line) {
                            continuation.yield(groups)
                        }
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
