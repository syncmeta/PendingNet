import SwiftUI
import SBTallyCore

private struct RuleSetInfo: Decodable, Identifiable {
    var tag: String
    var file: String
    var updated_at: String
    var id: String { tag }
}

struct ControlView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: EngineController

    @State private var rulesets: [RuleSetInfo] = []
    @State private var rulesetsUpdating = false
    @State private var rulesetsError: String?

    private let daemonBaseURL = URL(string: "http://127.0.0.1:7777")!

    private var vpsProxy: Proxy? { state.proxies["proxy"] }
    private var currentVPS: String { vpsProxy?.now ?? "" }
    private var protoProxy: Proxy? { state.proxies[currentVPS] }

    private func loadRulesets() async {
        do {
            let url = daemonBaseURL.appendingPathComponent("/api/rulesets")
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            rulesets = try JSONDecoder().decode([RuleSetInfo].self, from: data)
            rulesetsError = nil
        } catch {
            rulesetsError = String(describing: error)
        }
    }

    private func updateRulesets() async {
        rulesetsUpdating = true
        defer { rulesetsUpdating = false }
        do {
            var req = URLRequest(url: daemonBaseURL.appendingPathComponent("/api/rulesets/update"))
            req.httpMethod = "POST"
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            await loadRulesets()
        } catch {
            rulesetsError = String(describing: error)
        }
    }

    var body: some View {
        Form {
            Section("引擎") {
                if !engine.helperReady {
                    Button("需要授权特权助手…") { engine.registerHelper() }
                } else {
                    Toggle(engine.running ? "已连接" : "已停止", isOn: Binding(
                        get: { engine.running },
                        set: { on in Task { on ? await engine.start() : await engine.stop() } }
                    ))
                    .toggleStyle(.switch)
                }

                Picker("接管方式", selection: Binding(
                    get: { engine.takeover },
                    set: { m in Task { await engine.setTakeover(m) } }
                )) {
                    Text("TUN").tag("tun")
                    Text("系统代理").tag("sysproxy")
                    Text("仅端口").tag("local")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let err = engine.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if engine.startFailed && !engine.logTail.isEmpty {
                    ScrollView {
                        Text(engine.logTail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            Section("路由模式") {
                Picker("Mode", selection: Binding(
                    get: { state.mode },
                    set: { m in Task { await state.setMode(m) } }
                )) {
                    Text("全局").tag("Global")
                    Text("白名单").tag("Whitelist")
                    Text("黑名单").tag("Blacklist")
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

            Section("规则集") {
                if rulesets.isEmpty {
                    Text("暂无规则集").foregroundStyle(.secondary)
                } else {
                    ForEach(rulesets) { r in
                        HStack {
                            Text(r.tag)
                            Spacer()
                            Text(r.updated_at).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    Task { await updateRulesets() }
                } label: {
                    if rulesetsUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("立即更新")
                    }
                }
                .disabled(rulesetsUpdating)
                if let rulesetsError {
                    Text(rulesetsError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await state.loadControl()
            await loadRulesets()
        }
    }
}
