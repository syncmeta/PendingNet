import SwiftUI
import SBTallyCore

@MainActor
final class AppState: ObservableObject {
    @Published var since: String = "24h"
    @Published var apps: [AppStat] = []
    @Published var domains: [DomainStat] = []
    @Published var summary: Summary?
    @Published var live: [LiveAppGroup] = []
    @Published var lastError: String?

    let provider: StatsProvider
    private var liveTask: Task<Void, Never>?

    init(provider: StatsProvider) { self.provider = provider }

    func refresh() async {
        do {
            async let a = provider.apps(since: since, top: 50)
            async let d = provider.domains(since: since, top: 50)
            async let s = provider.summary(since: since)
            self.apps = try await a
            self.domains = try await d
            self.summary = try await s
            self.lastError = nil
        } catch {
            self.lastError = String(describing: error)
        }
    }

    func startLive() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let self else { return }
            for await groups in self.provider.live() {
                self.live = groups.sorted { ($0.upRate + $0.downRate) > ($1.upRate + $1.downRate) }
            }
        }
    }

    func stopLive() { liveTask?.cancel() }
}
