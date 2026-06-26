import SwiftUI
import SBTallyCore

struct ControlView: View {
    @EnvironmentObject var state: AppState

    private var vpsProxy: Proxy? { state.proxies["proxy"] }
    private var currentVPS: String { vpsProxy?.now ?? "" }
    private var protoProxy: Proxy? { state.proxies[currentVPS] }

    var body: some View {
        Form {
            Section("路由模式") {
                Picker("Mode", selection: Binding(
                    get: { state.mode },
                    set: { m in Task { await state.setMode(m) } }
                )) {
                    Text("规则").tag("Rule")
                    Text("全局").tag("Global")
                    Text("直连").tag("Direct")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let all = vpsProxy?.all {
                Section("VPS") {
                    Picker("VPS", selection: Binding(
                        get: { currentVPS },
                        set: { name in Task { await state.select(selector: "proxy", name: name) } }
                    )) {
                        ForEach(all, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if let all = protoProxy?.all {
                Section("协议 · \(currentVPS)") {
                    Picker("Protocol", selection: Binding(
                        get: { protoProxy?.now ?? "" },
                        set: { name in Task { await state.select(selector: currentVPS, name: name) } }
                    )) {
                        ForEach(all, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if state.proxies.isEmpty {
                ContentUnavailableView("无控制数据", systemImage: "slider.horizontal.3",
                                       description: Text("守护进程离线,或 sing-box 没有选择器。"))
            }
        }
        .formStyle(.grouped)
        .task { await state.loadControl() }
    }
}
