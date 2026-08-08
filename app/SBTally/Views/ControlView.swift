import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    @StateObject private var tester = VPSConnectivityTester()

    @State private var showingPairingImporter = false
    @Namespace private var scrollNamespace

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
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard(scroll: scroll)
                    vpsListCard
                }
                .padding(PendingNetTheme.Metrics.gutter)
                .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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

    // MARK: - One card: switch, takeover, routing, current VPS, protocol

    private func connectionCard(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PendingStatusPill(text: connectionStatus.0, kind: connectionStatus.1)
                if engine.takeover == "local" {
                    Text("127.0.0.1:\(engine.localProxyPort)")
                        .font(PendingNetTheme.Fonts.caption.monospaced())
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
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

            Picker("路由模式", selection: Binding(
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

            Divider().overlay(PendingNetTheme.Palette.hairline)

            // Read-only: picking a VPS happens in the list below.
            Button {
                withAnimation { scroll.scrollTo("vps-list", anchor: .top) }
            } label: {
                HStack {
                    Text("当前 VPS")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    if let server = appliedServer {
                        Text("\(server.name) · \(server.endpoint)")
                            .font(PendingNetTheme.Fonts.bodyEmphasized)
                            .foregroundStyle(PendingNetTheme.Palette.ink)
                    } else {
                        Text(vpsPairing.servers.isEmpty ? "尚未导入" : "未选择")
                            .font(PendingNetTheme.Fonts.body)
                            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let all = protoProxy?.all, let selector = appliedSelectorTag {
                HStack {
                    Text("协议")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    Picker("协议", selection: Binding(
                        get: { protoProxy?.now ?? "" },
                        set: { name in Task { await state.select(selector: selector, name: name) } }
                    )) {
                        ForEach(all, id: \.self) { Text(protocolLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PendingNetTheme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
        }
    }

    // MARK: - VPS list: pick one, test reachability

    private var vpsListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("VPS")
                    .font(PendingNetTheme.Fonts.sectionTitle("VPS"))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
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
                PendingEmptyState(
                    icon: "server.rack",
                    title: "还没有配对 VPS",
                    detail: "导入 .pdn 文件后，这里会列出你的 VPS。"
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(vpsPairing.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Divider().overlay(PendingNetTheme.Palette.hairline) }
                    serverRow(server)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PendingNetTheme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
        }
        .id("vps-list")
    }

    private func serverRow(_ server: PairedVPSServer) -> some View {
        let selected = server.serverID == appliedServer?.serverID
        return HStack(spacing: 14) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected
                    ? PendingNetTheme.Palette.success
                    : PendingNetTheme.Palette.hairline)

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
                switch tester.results[server.serverID] {
                case .reachable(let milliseconds, let detail):
                    Text("通 · \(milliseconds) ms · \(detail)")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.success)
                case .failed(let reason):
                    Text(reason)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }

            Spacer()

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
        .padding(.vertical, 4)
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
