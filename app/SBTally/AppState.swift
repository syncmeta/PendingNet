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
    @Published var mode: String = "Rule"
    @Published var proxies: [String: Proxy] = [:]

    let provider: StatsProvider & ControlProvider
    private var liveTask: Task<Void, Never>?

    init(provider: StatsProvider & ControlProvider) { self.provider = provider }

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

    func loadControl() async {
        do {
            let s = try await provider.controlState()
            self.mode = s.mode
            self.proxies = s.proxies
        } catch {
            self.lastError = String(describing: error)
        }
    }

    @discardableResult
    func select(selector: String, name: String) async -> Bool {
        do {
            try await provider.select(selector: selector, name: name)
            await loadControl()
            return true
        } catch {
            self.lastError = String(describing: error)
            return false
        }
    }

    func setMode(_ m: String) async {
        do {
            try await provider.setMode(m)
            self.mode = m
        } catch {
            self.lastError = String(describing: error)
        }
    }
}
