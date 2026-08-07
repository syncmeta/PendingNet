import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

private struct RuleSetInfo: Decodable, Identifiable {
    var tag: String
    var file: String
    var updated_at: String
    var id: String { tag }
}

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    @EnvironmentObject private var updater: PendingNetUpdateController

    @State private var rulesets: [RuleSetInfo] = []
    @State private var rulesetsUpdating = false
    @State private var rulesetsUnavailable = false
    @State private var showingPairingImporter = false

    private let daemonBaseURL = URL(string: "http://127.0.0.1:7777")!

    private var vpsProxy: Proxy? { state.proxies["proxy"] }
    private var currentVPS: String { vpsProxy?.now ?? "" }
    private var protoProxy: Proxy? { state.proxies[currentVPS] }

    private var connectionStatus: (String, PendingStatusPill.Kind) {
        if engine.takeover != "local" && !engine.helperReady { return ("等待授权", .neutral) }
        return engine.running ? ("已连接", .success) : ("已停止", .neutral)
    }

    private var friendlyEngineError: String? {
        guard let error = engine.lastError else { return nil }
        if error.localizedCaseInsensitiveContains("operation not permitted") {
            return "旧版后台服务仍在系统中。请先在系统设置里关闭 PendingNet 后台项目，再回来重新授权。"
        }
        if error.localizedCaseInsensitiveContains("could not connect") ||
            error.localizedCaseInsensitiveContains("助手连接失败") {
            return "后台服务尚未连接，请重新授权。"
        }
        return error
    }

    private func loadRulesets() async {
        do {
            let url = daemonBaseURL.appendingPathComponent("/api/rulesets")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            rulesets = try JSONDecoder().decode([RuleSetInfo].self, from: data)
            rulesetsUnavailable = false
        } catch {
            rulesetsUnavailable = true
        }
    }

    private func updateRulesets() async {
        rulesetsUpdating = true
        defer { rulesetsUpdating = false }
        do {
            var request = URLRequest(url: daemonBaseURL.appendingPathComponent("/api/rulesets/update"))
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            await loadRulesets()
        } catch {
            rulesetsUnavailable = true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PendingPageHeader(title: "连接")
                pairedServersCard
                engineCard
                routingCard
                rulesCard
                appUpdateCard
            }
            .padding(PendingNetTheme.Metrics.gutter)
            .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .task {
            await state.loadControl()
            await loadRulesets()
        }
        .fileImporter(
            isPresented: $showingPairingImporter,
            allowedContentTypes: [UTType(filenameExtension: "pdn") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await PendingNetConnectionWorkflow.importAndConnect(
                        url: url,
                        pairing: vpsPairing,
                        engine: engine,
                        state: state
                    )
                }
            case .failure(let error):
                vpsPairing.lastError = error.localizedDescription
            }
        }
    }

    private var pairedServersCard: some View {
        PendingSectionCard(
            "VPS",
            subtitle: ".pdn 只负责建立一次配对；协议材料由 VPS 后续下发。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if vpsPairing.servers.isEmpty {
                    HStack(spacing: 11) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 20))
                            .foregroundStyle(PendingNetTheme.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有配对 VPS")
                                .font(PendingNetTheme.Fonts.bodyEmphasized)
                                .foregroundStyle(PendingNetTheme.Palette.ink)
                            Text("请导入 VPS 生成的 .pdn 配对文件。")
                                .font(PendingNetTheme.Fonts.caption)
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        }
                    }
                } else {
                    ForEach(Array(vpsPairing.servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider().overlay(PendingNetTheme.Palette.hairline) }
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(PendingNetTheme.Fonts.bodyEmphasized)
                                    .foregroundStyle(PendingNetTheme.Palette.ink)
                                Text(server.endpoint)
                                    .font(PendingNetTheme.Fonts.caption.monospaced())
                                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                                if let protocols = server.nodeProtocols, !protocols.isEmpty {
                                    Text(protocols.joined(separator: " · "))
                                        .font(PendingNetTheme.Fonts.caption)
                                        .foregroundStyle(PendingNetTheme.Palette.accent)
                                }
                            }
                            Spacer()
                            Button("应用并连接") {
                                Task {
                                    await PendingNetConnectionWorkflow.refreshAndConnect(
                                        server: server,
                                        pairing: vpsPairing,
                                        engine: engine,
                                        state: state
                                    )
                                }
                            }
                            .buttonStyle(PendingPrimaryButtonStyle())
                            .disabled(vpsPairing.pairing)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        showingPairingImporter = true
                    } label: {
                        if vpsPairing.pairing {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("正在配对…")
                            }
                        } else {
                            Label("导入 .pdn", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(PendingQuietButtonStyle())
                    .disabled(vpsPairing.pairing)

                    if let message = vpsPairing.lastMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(PendingNetTheme.Fonts.caption)
                            .foregroundStyle(PendingNetTheme.Palette.success)
                    }
                }

                if let error = vpsPairing.lastError {
                    messageBanner(error, kind: .danger)
                }
            }
        }
    }

    private var engineCard: some View {
        PendingSectionCard(
            "本机代理",
            subtitle: "仅端口模式监听 127.0.0.1:\(engine.localProxyPort)，不会更改系统代理。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PendingStatusPill(text: connectionStatus.0, kind: connectionStatus.1)
                    Spacer()
                    if engine.takeover != "local" && !engine.helperReady {
                        Button("授权后台服务…") { engine.registerHelper() }
                            .buttonStyle(PendingPrimaryButtonStyle())
                    } else {
                        Toggle("连接", isOn: Binding(
                            get: { engine.running },
                            set: { on in Task { on ? await engine.start() : await engine.stop() } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("接管方式")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    Picker("接管方式", selection: Binding(
                        get: { engine.takeover },
                        set: { mode in Task { await engine.setTakeover(mode) } }
                    )) {
                        Text("仅端口").tag("local")
                        Text("系统代理").tag("sysproxy")
                        Text("TUN").tag("tun")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(engine.takeover == "local"
                         ? "应用自行运行本地代理，不需要后台服务授权。"
                         : "系统代理和 TUN 由已授权的后台服务接管。")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)

                    if engine.takeover == "local" && !engine.helperReady {
                        Button("授权后台服务…") { engine.registerHelper() }
                            .buttonStyle(PendingQuietButtonStyle())
                    }
                }

                if let error = friendlyEngineError {
                    messageBanner(error, kind: .danger)
                }

                if engine.startFailed && !engine.logTail.isEmpty {
                    DisclosureGroup("查看运行日志") {
                        ScrollView {
                            Text(engine.logTail)
                                .font(PendingNetTheme.Fonts.caption.monospaced())
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(.top, 8)
                    }
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
            }
        }
    }

    private var routingCard: some View {
        PendingSectionCard(
            "路由",
            subtitle: "路由规则保存在本机，不写入 .pdn 配对文件。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("规则模式")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    Picker("规则模式", selection: Binding(
                        get: { state.mode },
                        set: { mode in Task { await state.setMode(mode) } }
                    )) {
                        Text("全局").tag("Global")
                        Text("白名单").tag("Whitelist")
                        Text("黑名单").tag("Blacklist")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.proxies.isEmpty || engine.takeover == "local")
                }

                if engine.takeover == "local" {
                    messageBanner("当前仅端口模式使用全局转发；白名单、黑名单规则会作为独立的本机设置接入。", kind: .neutral)
                }

                if let all = vpsProxy?.all {
                    selectionRow("当前 VPS") {
                        Picker("当前 VPS", selection: Binding(
                            get: { currentVPS },
                            set: { name in Task { await state.select(selector: "proxy", name: name) } }
                        )) {
                            ForEach(all, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                if let all = protoProxy?.all {
                    selectionRow("当前协议") {
                        Picker("当前协议", selection: Binding(
                            get: { protoProxy?.now ?? "" },
                            set: { name in Task { await state.select(selector: currentVPS, name: name) } }
                        )) {
                            ForEach(all, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                if state.proxies.isEmpty {
                    messageBanner("代理尚未启动。导入 .pdn 并连接后，这里会显示 VPS 和协议。", kind: .neutral)
                }
            }
        }
    }

    private var rulesCard: some View {
        PendingSectionCard(
            "规则集",
            subtitle: "规则更新与 VPS 配对相互独立。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if rulesetsUnavailable {
                    messageBanner("统计与规则服务尚未启用，当前代理连接不受影响。", kind: .neutral)
                } else if rulesets.isEmpty {
                    Text("暂无规则集")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                } else {
                    ForEach(rulesets) { ruleset in
                        HStack {
                            Text(ruleset.tag)
                                .font(PendingNetTheme.Fonts.bodyEmphasized)
                            Spacer()
                            Text(ruleset.updated_at)
                                .font(PendingNetTheme.Fonts.caption)
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        }
                    }
                }

                Button {
                    Task { await updateRulesets() }
                } label: {
                    if rulesetsUpdating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                        }
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(rulesetsUpdating)
            }
        }
    }

    private var appUpdateCard: some View {
        PendingSectionCard(
            "应用更新",
            subtitle: "自动检查、验证签名并安全替换 PendingNet。"
        ) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前版本 \(updater.currentVersion)")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Text(updater.isConfigured
                         ? "已启用自动检查与后台下载"
                         : "更新发布地址尚未配置")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
                Spacer()
                Button("检查更新…") { updater.checkForUpdates() }
                    .buttonStyle(PendingQuietButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    @ViewBuilder
    private func selectionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(PendingNetTheme.Fonts.body)
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            content()
        }
    }

    private func messageBanner(_ text: String, kind: PendingStatusPill.Kind) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .danger ? "exclamationmark.circle.fill" : "info.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(PendingNetTheme.Fonts.caption)
        .foregroundStyle(kind == .danger
            ? PendingNetTheme.Palette.danger
            : PendingNetTheme.Palette.inkMuted)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind == .danger
            ? PendingNetTheme.Palette.dangerBackground
            : PendingNetTheme.Palette.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
