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
