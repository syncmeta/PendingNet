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
    /// 读统计接口失败的那一次。刻意和 `lastError` 分开：那一个说的是引擎控制口
    /// （选 VPS、切模式）出了什么事，统计页面拿它当「统计服务没起来」用了很久，
    /// 于是切个模式失败也会让统计页说「统计服务尚未启用」。
    @Published var statsError: String?
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
    private let selectorPreferences: PendingNetSelectorPreferences
    private static let modeKey = "pendingnet.route-mode"
    private var liveTask: Task<Void, Never>?

    init(provider: StatsProvider & ControlProvider, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        self.selectorPreferences = PendingNetSelectorPreferences(defaults: defaults)
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
            self.statsError = nil
        } catch {
            self.statsError = String(describing: error)
        }
    }

    /// 订阅实时流量。断了就重订 —— 统计服务跟着引擎一起启停（换端口、开分流、
    /// 换 VPS 都会重启一次），从前这里只订一次，重启之后实时页就永远空着，
    /// 而且看上去和「没有流量」一模一样。
    func startLive() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await groups in self.provider.live() {
                    self.live = groups.sorted { ($0.upRate + $0.downRate) > ($1.upRate + $1.downRate) }
                }
                if Task.isCancelled { return }
                self.live = []
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopLive() { liveTask?.cancel() }

    func loadControl() async {
        do {
            var s = try await provider.controlState()
            var restoredASelection = false
            for (selector, selection) in selectorPreferences.restorableSelections(
                in: s.proxies
            ) {
                do {
                    try await provider.select(selector: selector, name: selection)
                    restoredASelection = true
                } catch {
                    // 一台 VPS 或一种协议已经失效，不该拦住其它仍有效的选择和
                    // 路由模式恢复。下一次配置刷新后还会重新判断它是否有效。
                }
            }
            if restoredASelection {
                s = try await provider.controlState()
            }
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
            selectorPreferences.remember(selector: selector, selection: name)
            await loadControl()
            return proxies[selector]?.now == name
        } catch {
            self.lastError = String(describing: error)
            return false
        }
    }

}
