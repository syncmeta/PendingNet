import Foundation

/// 开机恢复只记“用户最后一次把连接开关停在哪”。
///
/// 是否真的随登录启动由 macOS 的 `SMAppService.mainApp` 负责；这份存档不复制
/// 那个系统状态，避免用户在「登录项与扩展」里关掉后 App 仍自以为开着。
public struct PendingNetStartupPreferences {
    public static let connectedKey = "pendingnet.restore-connected-state"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var wasConnected: Bool {
        defaults.bool(forKey: Self.connectedKey)
    }

    public func rememberConnected(_ connected: Bool) {
        defaults.set(connected, forKey: Self.connectedKey)
    }
}

/// sing-box 的 selector 选择默认不会跨进程重启保留。这里记住顶层 VPS selector，
/// 也记住每台 VPS 里面的协议 selector，开机恢复时才不会只恢复到“差不多”。
public struct PendingNetSelectorPreferences {
    public static let selectionsKey = "pendingnet.selector-selections"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selections: [String: String] {
        defaults.dictionary(forKey: Self.selectionsKey) as? [String: String] ?? [:]
    }

    public func remember(selector: String, selection: String) {
        guard !selector.isEmpty, !selection.isEmpty else { return }
        var next = selections
        next[selector] = selection
        defaults.set(next, forKey: Self.selectionsKey)
    }

    /// 只交回当前配置仍认识的选择。VPS 被删、协议被服务端撤掉之后，旧存档不能
    /// 让恢复流程报错，更不能阻止其它仍有效的选择落地。
    public func restorableSelections(in proxies: [String: Proxy]) -> [(String, String)] {
        selections.compactMap { selector, selection in
            guard let proxy = proxies[selector],
                  proxy.all?.contains(selection) == true,
                  proxy.now != selection else { return nil }
            return (selector, selection)
        }
        .sorted { $0.0 < $1.0 }
    }
}
