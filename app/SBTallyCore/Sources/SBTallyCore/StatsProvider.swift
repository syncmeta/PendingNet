import Foundation

public protocol StatsProvider {
    func summary(since: String) async throws -> Summary
    func apps(since: String, top: Int) async throws -> [AppStat]
    func domains(since: String, top: Int) async throws -> [DomainStat]
    func appDetail(_ name: String, since: String) async throws -> AppDetail
    func series(name: String?, since: String) async throws -> [Point]
    func live() -> AsyncStream<[LiveAppGroup]>
}
