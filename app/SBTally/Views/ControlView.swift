import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    @StateObject private var tester = VPSConnectivityTester()

    @State private var showingPairingImporter = false
    @State private var detailServerID: String?

    /// The sing-box selector tag the engine currently routes through, if it is
    /// one of our managed VPS tags (`direct` and friends are engine outbounds,
    /// not VPS choices).
    private var appliedSelectorTag: String? { state.proxies["proxy"]?.now }

    /// The paired VPS that tag belongs to — nil when nothing has been applied yet.
    private var appliedServer: PairedVPSServer? {
        guard let tag = appliedSelectorTag else { return nil }
        return vpsPairing.servers.first {
            PendingNetRuntimeServer.selectorTag(forServerID: $0.serverID) == tag
        }
    }

    /// Per-VPS protocol selector (vless-reality / hysteria2 inside one VPS).
    private var protoProxy: Proxy? {
        guard appliedServer != nil, let tag = appliedSelectorTag else { return nil }
        return state.proxies[tag]
    }

    private func protocolLabel(_ tag: String) -> String {
        guard let selector = appliedSelectorTag, tag.hasPrefix(selector + "-") else { return tag }
        return String(tag.dropFirst(selector.count + 1))
    }

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
            connectionCard
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

    // MARK: - One card, one kind of control: pills all the way down

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            PendingPillPicker(
                options: [
                    .init("local", "仅端口"),
                    .init("sysproxy", "系统代理"),
                    .init("tun", "TUN"),
                ],
                selection: engine.takeover
            ) { mode in
                Task {
                    await engine.setTakeover(mode)
                    await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                PendingPillPicker(
                    options: [
                        .init("Global", "全局"),
                        .init("Whitelist", "白名单"),
                        .init("Blacklist", "黑名单"),
                    ],
                    selection: state.mode
                ) { mode in
                    Task {
                        await PendingNetRoutingWorkflow.select(
                            mode: mode, engine: engine, state: state
                        )
                    }
                }
                if let note = state.modeNote {
                    Text(note)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            vpsList
                .padding(.top, 10)

            if let all = protoProxy?.all, let selector = appliedSelectorTag {
                PendingPillPicker(
                    options: all.map { .init($0, protocolLabel($0)) },
                    selection: protoProxy?.now
                ) { name in
                    Task { await state.select(selector: selector, name: name) }
                }
            }

            if let error = friendlyEngineError {
                messageBanner(error, kind: .danger)
            }

            if let error = vpsPairing.lastError {
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PendingNetTheme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PendingStatusPill(text: connectionStatus.0, kind: connectionStatus.1)
            Spacer()
            if engine.takeover != "local" && !engine.helperReady {
                Button("授权后台服务…") { engine.registerHelper() }
                    .buttonStyle(PendingPrimaryButtonStyle())
            } else {
                Toggle("连接", isOn: Binding(
                    get: { engine.running },
                    set: { on in
                        Task {
                            await PendingNetConnectionWorkflow.setConnected(
                                on, engine: engine, state: state
                            )
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    // MARK: - VPS: 竖排列表，选中的那行前面打勾

    private var vpsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer()
                if vpsPairing.servers.count > 1 {
                    Button("测试全部") { testAll() }
                        .buttonStyle(PendingQuietButtonStyle())
                        .disabled(tester.busy || vpsPairing.pairing)
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

            if vpsPairing.servers.isEmpty {
                Text("还没有配对 VPS，导入 .pdn 后这里会列出你的服务器。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vpsPairing.servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider().overlay(PendingNetTheme.Palette.hairline) }
                        vpsRow(server)
                    }
                }
                .background(PendingNetTheme.Palette.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
                }
            }
        }
    }

    private func vpsRow(_ server: PairedVPSServer) -> some View {
        let selected = server.serverID == appliedServer?.serverID
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .opacity(selected ? 1 : 0)
                .frame(width: 14)
            // verbatim: 地址是标识符，不能被本地化
            Text(verbatim: server.address)
                .font(selected
                    ? PendingNetTheme.Fonts.bodyEmphasized.monospaced()
                    : PendingNetTheme.Fonts.body.monospaced())
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            Button("详情") { detailServerID = server.serverID }
                .buttonStyle(.plain)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .popover(isPresented: Binding(
                    get: { detailServerID == server.serverID },
                    set: { if !$0 { detailServerID = nil } }
                ), arrowEdge: .bottom) {
                    serverDetail(server)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected, !vpsPairing.pairing else { return }
            Task {
                await PendingNetConnectionWorkflow.refreshAndConnect(
                    server: server,
                    pairing: vpsPairing,
                    engine: engine,
                    state: state
                )
            }
        }
    }

    /// 端口、支持的协议、连通性测试 —— 主界面只放 IP，细节都在这里。
    private func serverDetail(_ server: PairedVPSServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(server.name)
                .font(PendingNetTheme.Fonts.bodyEmphasized)
                .foregroundStyle(PendingNetTheme.Palette.ink)

            detailRow("地址", server.address, monospaced: true)
            if let port = server.controlPort {
                // verbatim: 端口是标识符不是数量（否则 7443 会被显示成 "7,443"）
                detailRow("端口", port, monospaced: true)
            }
            if let protocols = server.nodeProtocols, !protocols.isEmpty {
                detailRow("支持的协议", protocols.joined(separator: " · "))
            }

            switch tester.results[server.serverID] {
            case .reachable(let milliseconds, let detail):
                Text(verbatim: "通 · \(milliseconds) ms · \(detail)")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Text(reason)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            Button {
                Task { await test(server) }
            } label: {
                if tester.isTesting(server.serverID) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("测试中…")
                    }
                } else {
                    Text("测试")
                }
            }
            .buttonStyle(PendingQuietButtonStyle())
            .disabled(tester.isTesting(server.serverID))
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            Spacer()
            // verbatim: 地址/端口都是标识符，不能被本地化成千分位数字
            Text(verbatim: value)
                .font(monospaced
                    ? PendingNetTheme.Fonts.caption.monospaced()
                    : PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.ink)
        }
    }

    private func test(_ server: PairedVPSServer) async {
        let tag = server.serverID == appliedServer?.serverID && engine.running
            ? appliedSelectorTag
            : nil
        await tester.test(server, throughProxyTag: tag)
    }

    private func testAll() {
        for server in vpsPairing.servers {
            Task { await test(server) }
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
