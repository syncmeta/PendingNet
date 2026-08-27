import Foundation
import SBTallyCore

@MainActor
enum PendingNetConnectionWorkflow {
    static func importAndConnect(
        url: URL,
        pairing: VPSPairingController,
        engine: EngineController,
        state: AppState
    ) async {
        guard let runtime = await pairing.importAndEnroll(url: url) else { return }
        await applyAndConnect(runtime, pairing: pairing, engine: engine, state: state)
    }

    /// 用户粘进来的一段文本：一条 `pendingnet://` 配对链接，或者 `.pdn` 原文。
    static func importAndConnect(
        pasted text: String,
        pairing: VPSPairingController,
        engine: EngineController,
        state: AppState
    ) async {
        guard let runtime = await pairing.importAndEnroll(pasted: text) else { return }
        await applyAndConnect(runtime, pairing: pairing, engine: engine, state: state)
    }

    /// 系统从外面递进来的一个 URL：双击的 `.pdn`，或者点开的 `pendingnet://`
    /// 配对链接。两条路走同一条配对流程，唯一的分别是从哪儿读出那份凭据。
    ///
    /// 认不出来的 URL 一律不理：`importAndEnroll` 里是 `Data(contentsOf:)`，
    /// 把一个 http URL 放进来就成了一次同步网络请求。
    static func importAndConnect(
        opened url: URL,
        pairing: VPSPairingController,
        engine: EngineController,
        state: AppState
    ) async {
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "pdn" else { return }
            await importAndConnect(url: url, pairing: pairing, engine: engine, state: state)
            return
        }
        guard url.scheme?.lowercased() == PendingNetPairingFile.urlScheme else { return }
        await importAndConnect(
            pasted: url.absoluteString, pairing: pairing, engine: engine, state: state
        )
    }

    /// 开关：起停引擎，起来之后按记住的路由模式生效。
    static func setConnected(
        _ on: Bool,
        engine: EngineController,
        state: AppState
    ) async {
        if on {
            await engine.start()
            guard engine.running else { return }
            if engine.takeover == "local" {
                await state.loadControl()
            } else {
                state.clearLocalControl()
            }
            await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
        } else {
            await engine.stop()
            if !engine.running { state.clearLocalControl() }
        }
    }

    static func refreshAndConnect(
        server: PairedVPSServer,
        pairing: VPSPairingController,
        engine: EngineController,
        state: AppState
    ) async {
        guard let runtime = await pairing.runtimeServer(for: server) else { return }
        await applyAndConnect(runtime, pairing: pairing, engine: engine, state: state)
    }

    private static func applyAndConnect(
        _ runtime: PendingNetRuntimeServer,
        pairing: VPSPairingController,
        engine: EngineController,
        state: AppState
    ) async {
        guard engine.takeover == "local" || engine.helperReady else {
            pairing.reportApplyError("VPS 已配对。当前请先切换到“仅端口”，再点“应用并连接”")
            return
        }
        guard await engine.applyServerConfiguration(runtime) else {
            pairing.reportApplyError(engine.lastError ?? "应用本机配置失败")
            return
        }
        // 用户可能刚在 Terminal 停掉旧 LaunchDaemon；界面上的 `running` 是上一拍
        // 的快照，先回读真实状态，不能拿它直接决定“无需启动”。
        await engine.refresh()
        if !engine.running {
            await engine.start()
            guard engine.running else {
                pairing.reportApplyError(engine.lastError ?? "sing-box 启动失败")
                return
            }
        }

        // TUN / 系统代理由 helper 写配置、重启并选择 selector；它的 9090 控制口
        // 密钥不会交给 App。旧代码仍去请求仅端口专属的 29090，选择其实已经成功，
        // 界面却永远读不到状态，也不会画勾。
        if engine.takeover != "local" {
            await engine.refresh()
            guard engine.activeSelectorTag == runtime.selectorTag else {
                pairing.reportApplyError("配置已写入，但无法确认正在使用的 VPS")
                return
            }
            pairing.markApplied(runtime)
            state.clearLocalControl()
            await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
            return
        }

        for attempt in 0..<20 {
            if await state.select(selector: "proxy", name: runtime.selectorTag) {
                pairing.markApplied(runtime)
                await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
                return
            }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        pairing.reportApplyError(state.lastError ?? "配置已写入，但自动选择 VPS 失败")
    }
}
