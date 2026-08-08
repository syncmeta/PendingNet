import Foundation

public struct AppStat: Codable, Identifiable, Hashable {
    public let app: String
    public let upload, download, total: Int64
    public var id: String { app }
}

public struct DomainStat: Codable, Identifiable, Hashable {
    public let host: String
    public let upload, download, total: Int64
    public var id: String { host }
}

public struct AppDetail: Codable {
    public let app: String
    public let domains: [DomainStat]
}

public struct Point: Codable, Identifiable {
    public let bucket: Int64
    public let upload, download: Int64
    public var id: Int64 { bucket }
}

public struct Summary: Codable {
    public let since: Int64
    public let upload, download, total: Int64
    public let apps, hosts: Int
}

public struct LiveAppGroup: Codable, Identifiable, Hashable {
    public let app: String
    public let upRate, downRate: Int64
    public let conns: Int
    public let topHost: String
    public var id: String { app }
}

public struct Proxy: Codable, Hashable {
    public let type: String
    public let now: String?
    public let all: [String]?
}

public struct ControlState: Codable {
    public let mode: String
    public let proxies: [String: Proxy]
    /// The modes the running engine will actually accept. Empty when the source
    /// doesn't report one — a switch to an unlisted mode is silently ignored by
    /// sing-box, so the GUI needs this to tell the user rather than pretend.
    public let modeList: [String]

    public init(mode: String, proxies: [String: Proxy], modeList: [String] = []) {
        self.mode = mode
        self.proxies = proxies
        self.modeList = modeList
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        proxies = try container.decode([String: Proxy].self, forKey: .proxies)
        modeList = try container.decodeIfPresent([String].self, forKey: .modeList) ?? []
    }
}
