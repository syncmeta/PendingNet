import Combine
import Foundation
import ServiceManagement

/// macOS 登录项只负责把 App 拉起来；连接是否恢复、恢复成什么状态仍由 App 自己
/// 根据上次的连接开关和各项持久化设置决定。这样三种接管方式走的是同一套语义，
/// 不会再由 root LaunchDaemon 擅自把所有机器固定拉进 TUN。
@MainActor
final class PendingNetStartupController: ObservableObject {
    @Published private(set) var startsAtLogin = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp
    private var didAttemptRestore = false

    init() {
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            startsAtLogin = true
            requiresApproval = false
            lastError = nil
        case .requiresApproval:
            startsAtLogin = false
            requiresApproval = true
            lastError = "请在系统设置 → 通用 → 登录项与扩展中允许 PendingNet。"
        case .notRegistered, .notFound:
            startsAtLogin = false
            requiresApproval = false
        @unknown default:
            startsAtLogin = false
            requiresApproval = false
        }
    }

    func setStartsAtLogin(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            lastError = enabled
                ? "开机自启没能打开：\(error.localizedDescription)"
                : "开机自启没能关闭：\(error.localizedDescription)"
        }
    }

    /// Window 的 `.task` 可能因视图重建跑多次；一次进程生命周期只恢复一次，
    /// 否则一次前后台切换就可能把用户刚关掉的连接重新打开。
    func restoreIfNeeded(engine: EngineController, state: AppState) async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        refresh()
        guard startsAtLogin, engine.shouldReconnectOnLaunch, !engine.running else { return }
        await PendingNetConnectionWorkflow.setConnected(true, engine: engine, state: state)
    }
}
