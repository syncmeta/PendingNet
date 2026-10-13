import SwiftUI
import AppKit
import SBTallyCore

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    @EnvironmentObject private var navigation: PendingNetNavigation
    @Environment(\.openWindow) private var openWindow

    private var selector: String? {
        engine.takeover == "local" ? state.proxies["proxy"]?.now : engine.activeSelectorTag
    }

    var body: some View {
        if engine.takeover != "local" && !engine.helperReady {
            Button("授权后台服务…") { engine.registerHelper() }
        } else {
            Toggle("连接", isOn: Binding(get: { engine.running }, set: { on in
                Task { await PendingNetConnectionWorkflow.setConnected(on, pairing: vpsPairing, engine: engine, state: state) }
            }))
            .disabled(engine.connectionBusy || vpsPairing.pairing)
        }
        Picker("模式", selection: Binding(get: { engine.takeover }, set: { mode in
            Task { await PendingNetConnectionWorkflow.setTakeover(mode, engine: engine, state: state) }
        })) {
            Text("仅端口").tag("local")
            Text("系统代理").tag("sysproxy")
            Text("TUN").tag("tun")
        }
        .pickerStyle(.inline)
        .disabled(engine.connectionBusy || vpsPairing.pairing)
        Divider()
        Picker("路由", selection: Binding(get: { state.mode }, set: { mode in
            guard let selected = PendingNetRouteMode.clashNamed(mode) else { return }
            Task { await PendingNetConnectionWorkflow.setRouteMode(selected, engine: engine, state: state) }
        })) {
            Text("全局").tag(PendingNetRouteMode.global.clashName)
            Text("白名单").tag(PendingNetRouteMode.whitelist.clashName)
            Text("黑名单").tag(PendingNetRouteMode.blacklist.clashName)
        }
        .pickerStyle(.inline)
        .disabled(engine.connectionBusy || vpsPairing.pairing)
        Menu("节点") {
            ForEach(vpsPairing.servers) { server in
                Button {
                    Task { await PendingNetConnectionWorkflow.refreshAndConnect(server: server, pairing: vpsPairing, engine: engine, state: state) }
                } label: {
                    if selector == PendingNetRuntimeServer.selectorTag(forServerID: server.serverID) {
                        Label(server.name.isEmpty ? server.address : server.name, systemImage: "checkmark")
                    } else { Text(verbatim: server.name.isEmpty ? server.address : server.name) }
                }
            }
        }
        .disabled(engine.connectionBusy || vpsPairing.pairing || vpsPairing.servers.isEmpty)
        Divider()
        Button("打开主窗口") { navigation.section = .connection; openWindow(id: "main") }
        Button("设置") { navigation.section = .settings; openWindow(id: "main") }
            .keyboardShortcut(",")
        Button("退出 PendingNet") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
