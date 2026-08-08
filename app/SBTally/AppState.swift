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
    /// 用户选中的路由模式。这是「记住的选择」，不是引擎的当前状态：引擎没跑时
    /// 也照样能改，起来之后再按它生效。
    @Published private(set) var mode: String
    /// The modes the running engine will accept; empty when it isn't reachable.
    @Published private(set) var modeList: [String] = []
    /// Plain-language reason the remembered mode isn't in effect yet, if any.
    @Published var modeNote: String?
    @Published var proxies: [String: Proxy] = [:]

    let provider: StatsProvider & ControlProvider
    private let defaults: UserDefaults
    private static let modeKey = "pendingnet.route-mode"
    private var liveTask: Task<Void, Never>?

    init(provider: StatsProvider & ControlProvider, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        self.mode = defaults.string(forKey: Self.modeKey) ?? "Global"
    }

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
            self.proxies = s.proxies
            self.modeList = s.modeList
            // 引擎跑起来了但模式不是记住的那个 —— 把记住的推过去，而不是让引擎
            // 的状态把用户的选择覆盖掉。
            if s.mode != mode, s.modeList.isEmpty || s.modeList.contains(mode) {
                _ = await pushMode()
            } else if s.mode == mode {
                self.modeNote = nil
            }
        } catch {
            self.lastError = String(describing: error)
        }
    }

    /// 记住用户选的模式。任何时候都能调用，不需要引擎在跑。
    func rememberMode(_ m: String) {
        mode = m
        defaults.set(m, forKey: Self.modeKey)
    }

    /// Pushes the remembered mode to the engine and reports whether the engine
    /// really adopted it. The Clash API answers 204 even for a mode the running
    /// config never declares, so the result has to be read back.
    @discardableResult
    func pushMode() async -> Bool {
        do {
            try await provider.setMode(mode)
            let s = try await provider.controlState()
            self.proxies = s.proxies
            self.modeList = s.modeList
            return s.mode == mode
        } catch {
            return false
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

}
