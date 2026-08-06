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
        if !engine.running {
            await engine.start()
            guard engine.running else {
                pairing.reportApplyError(engine.lastError ?? "sing-box 启动失败")
                return
            }
        }

        for attempt in 0..<20 {
            if await state.select(selector: "proxy", name: runtime.selectorTag) {
                pairing.markApplied(runtime)
                return
            }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        pairing.reportApplyError(state.lastError ?? "配置已写入，但自动选择 VPS 失败")
    }
}
