import SwiftUI
import AppKit
import SBTallyCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: EngineController
    @Environment(\.openWindow) private var openWindow

    private var totalUp: Int64 { state.live.reduce(0) { $0 + $1.upRate } }
    private var totalDown: Int64 { state.live.reduce(0) { $0 + $1.downRate } }

    private var vpsProxy: Proxy? { state.proxies["proxy"] }
    private var currentVPS: String { vpsProxy?.now ?? "" }
    private var protoProxy: Proxy? { state.proxies[currentVPS] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !engine.helperReady {
                Button("需要授权特权助手…") { engine.registerHelper() }
            } else {
                Toggle(engine.running ? "已连接" : "已停止", isOn: Binding(
                    get: { engine.running },
                    set: { on in Task { on ? await engine.start() : await engine.stop() } }))
                    .toggleStyle(.switch)
            }
            Picker("接管", selection: Binding(
                get: { engine.takeover },
                set: { m in Task { await engine.setTakeover(m) } })) {
                Text("TUN").tag("tun"); Text("系统代理").tag("sysproxy"); Text("仅端口").tag("local")
            }
            Picker("规则", selection: Binding(
                get: { state.mode },
                set: { m in Task { await state.setMode(m) } })) {
                Text("全局").tag("Global"); Text("白名单").tag("Whitelist"); Text("黑名单").tag("Blacklist")
            }
            if let all = vpsProxy?.all {
                Picker("VPS", selection: Binding(
                    get: { currentVPS },
                    set: { name in Task { await state.select(selector: "proxy", name: name) } })) {
                    ForEach(all, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if let all = protoProxy?.all {
                Picker("协议", selection: Binding(
                    get: { protoProxy?.now ?? "" },
                    set: { name in Task { await state.select(selector: currentVPS, name: name) } })) {
                    ForEach(all, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if let err = engine.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            if engine.startFailed && !engine.logTail.isEmpty {
                ScrollView {
                    Text(engine.logTail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Divider()

            Text("↑ \(humanBytes(totalUp))/s   ↓ \(humanBytes(totalDown))/s")
                .monospacedDigit()
                .font(.headline)
            if state.live.isEmpty {
                Text("暂无流量").foregroundStyle(.secondary)
            } else {
                ForEach(state.live.prefix(5)) { g in
                    Text("\(g.app) — ↓\(humanBytes(g.downRate))/s ↑\(humanBytes(g.upRate))/s")
                        .monospacedDigit()
                }
            }

            Divider()
            Button("打开 PendingNet") { openWindow(id: "main") }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .pickerStyle(.segmented)
        .padding(10)
        .frame(width: 300)
        .task {
            await engine.refresh()
            await state.loadControl()
        }
    }
}
