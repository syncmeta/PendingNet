import Foundation
import SBTallyCore

/// 路由模式（全局 / 白名单 / 黑名单）的选择与生效。
///
/// The user's pick is recorded first and unconditionally — it is a preference,
/// not a command the engine has to be alive to accept. Making it take effect is
/// a separate, best-effort step, and whatever stands in the way is reported in
/// words instead of being swallowed (or, as before, hidden behind a disabled
/// control that never explained itself).
@MainActor
enum PendingNetRoutingWorkflow {
    private static let listModes = ["Whitelist", "Blacklist"]

    static func select(
        mode: String,
        engine: EngineController,
        state: AppState
    ) async {
        state.rememberMode(mode)
        state.modeNote = nil
        await apply(engine: engine, state: state, userInitiated: true)
    }

    /// Re-applies whatever mode is remembered — call after the engine starts or
    /// after a VPS is applied, so a choice made while it was down lands.
    static func applyRemembered(engine: EngineController, state: AppState) async {
        await apply(engine: engine, state: state, userInitiated: false)
    }

    private static func apply(
        engine: EngineController,
        state: AppState,
        userInitiated: Bool
    ) async {
        let mode = state.mode
        guard engine.takeover == "local" else {
            // sysproxy/TUN 的引擎由后台服务另起一份，app 够不着它的控制端口。
            state.modeNote = "已记住。当前是「\(takeoverName(engine.takeover))」接管，路由由后台服务的配置决定，"
                + "切回「仅端口」后这里的选择才会生效。"
            return
        }
        guard engine.running else {
            state.modeNote = mode == "Global" ? nil : "已记住，连接后生效。"
            return
        }
        if listModes.contains(mode), !engine.listModesAvailable {
            state.modeNote = "正在准备分流名单…"
            guard await engine.enableListModes() else {
                state.modeNote = "分流名单还没下载到（要能访问 GitHub，通常连上代理后就能拿到）。"
                    + "已记住你的选择，下次连接会自动再试，在那之前按全局走。"
                return
            }
        }
        guard await state.pushMode() else {
            state.modeNote = userInitiated
                ? "引擎没有接受这个模式，已记住你的选择，重新连接后会再试。"
                : "已记住，重新连接后生效。"
            return
        }
        state.modeNote = nil
    }

    private static func takeoverName(_ takeover: String) -> String {
        switch takeover {
        case "sysproxy": "系统代理"
        case "tun": "TUN"
        default: "仅端口"
        }
    }
}
