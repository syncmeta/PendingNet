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
    /// 需要分流名单的那两档，用的还是 `clashName` 那一份对照表——这里再手写
    /// 一遍 "Whitelist" 就等于又开了一处会和它走散的写法。
    private static let listModes = [PendingNetRouteMode.whitelist, .blacklist].map(\.clashName)

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
            // sysproxy/TUN 的引擎由后台服务另起一份，app 够不着它的控制端口，
            // 只能请后台服务代切。
            await applyThroughHelper(
                mode: mode, engine: engine, state: state, userInitiated: userInitiated)
            return
        }
        guard engine.running else {
            // 没连接时选路由不是异常：选择已经记住，连上就按它走，
            // 所以这里不留回执——点亮的那颗药丸自己就是回执。
            state.modeNote = nil
            return
        }
        if listModes.contains(mode), !engine.listModeAvailable(mode) {
            state.modeNote = "正在准备分流名单…"
            guard await engine.enableListMode(mode) else {
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

    /// TUN / 系统代理：路由归后台服务管，模式也由它切。
    ///
    /// 它还会把选择落盘，所以引擎没在跑时这一趟也不白走 —— 下次起来就按这个
    /// 模式走，不用用户再点一次。
    private static func applyThroughHelper(
        mode: String,
        engine: EngineController,
        state: AppState,
        userInitiated: Bool
    ) async {
        switch await engine.setRouteMode(mode) {
        case .applied:
            state.modeNote = nil
        case .unreachable(let reason):
            guard userInitiated else {
                // 不是用户刚点的：连接卡上「等待授权」那套已经在说这件事了，
                // 这里再补一句只是重复。
                state.modeNote = nil
                return
            }
            state.modeNote = "已记住。「\(takeoverName(engine.takeover))」接管下的路由要由后台服务来切，"
                + "而现在够不着它（\(reason)）。授权后台服务后这个选择就会生效。"
        case .rejected(let reason):
            state.modeNote = userInitiated
                ? "后台服务没能切到这个模式：\(reason)。已记住你的选择，重新连接后会再试。"
                : "已记住，重新连接后生效。"
        }
    }

    private static func takeoverName(_ takeover: String) -> String {
        switch takeover {
        case "sysproxy": "系统代理"
        case "tun": "TUN"
        default: "仅端口"
        }
    }
}
