import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController

    @State private var showingPairingImporter = false

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
            // Pending approval is the common case; a leftover legacy
            // registration is only plausible once approval is done.
            if engine.helperNeedsApproval {
                return "请在系统设置 → 通用 → 登录项与扩展中允许 PendingNet 后台项目。"
            }
            return "旧版后台服务仍在系统中。请先在系统设置里关闭 PendingNet 后台项目，再回来重新授权。"
        }
        if error.localizedCaseInsensitiveContains("could not connect") ||
            error.localizedCaseInsensitiveContains("助手连接失败") {
            return "后台服务尚未连接，请重新授权。"
        }
        return error
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PendingPageHeader(title: "连接")
                engineCard
                routingCard
                pairedServersCard
            }
            .padding(PendingNetTheme.Metrics.gutter)
            .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .task {
            await state.loadControl()
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
        PendingSectionCard("VPS") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("当前 VPS")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    if let all = vpsProxy?.all {
                        Picker("当前 VPS", selection: Binding(
                            get: { currentVPS },
                            set: { name in Task { await state.select(selector: "proxy", name: name) } }
                        )) {
                            ForEach(all, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    } else {
                        Text("代理尚未启动")
                            .font(PendingNetTheme.Fonts.caption)
                            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    }

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

                Divider().overlay(PendingNetTheme.Palette.hairline)

                if vpsPairing.servers.isEmpty {
                    HStack(spacing: 11) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 20))
                            .foregroundStyle(PendingNetTheme.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有配对 VPS")
                                .font(PendingNetTheme.Fonts.bodyEmphasized)
                                .foregroundStyle(PendingNetTheme.Palette.ink)
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

                if let message = vpsPairing.lastMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.success)
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
            subtitle: engine.takeover == "local" ? "127.0.0.1:\(engine.localProxyPort)" : nil
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

                if state.proxies.isEmpty {
                    messageBanner("代理尚未启动。导入 .pdn 并连接后，这里可以切换规则模式。", kind: .neutral)
                }
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
