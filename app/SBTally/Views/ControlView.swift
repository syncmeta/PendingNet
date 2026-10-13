import SBTallyCore
import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    /// 每台 VPS 一个延迟数，语义和 iOS 那边完全一样（见
    /// `PendingNetLatencyTarget`）：到这台 VPS 代理入口的 TCP 握手往返时间。
    @StateObject private var latency = PendingNetLatencyTester()

    @State private var showingPasteImport = false
    @State private var editingNodes = false
    @AppStorage(PendingNetLatencyMethod.preferenceKey) private var latencyMethod = "tcp"
    @State private var detailServerID: String?
    @State private var deletingServerID: String?

    /// The sing-box selector tag the engine currently routes through, if it is
    /// one of our managed VPS tags (`direct` and friends are engine outbounds,
    /// not VPS choices).
    private var appliedSelectorTag: String? {
        engine.takeover == "local" ? state.proxies["proxy"]?.now : engine.activeSelectorTag
    }

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
        return engine.takeover == "local" ? state.proxies[tag] : engine.protocolProxy
    }

    private var connectionStatus: (String, PendingStatusPill.Kind) {
        if engine.connectionBusy { return ("正在切换", .neutral) }
        if engine.takeover != "local" && !engine.helperReady { return ("等待授权", .neutral) }
        return engine.running ? ("已连接", .success) : ("已停止", .neutral)
    }

    /// `state.mode` 是 Clash 那边的写法（引擎回读的、或我们发下去的）。翻回
    /// 档位一律走 `clashNamed`，不靠大小写变换——见 `PendingNetClashControl`。
    private var routeMode: PendingNetRouteMode? {
        PendingNetRouteMode.clashNamed(state.mode)
    }

    var body: some View {
        ScrollView {
            connectionCard
                .padding(PendingNetTheme.Metrics.gutter)
                .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .alert("删除 VPS？", isPresented: Binding(get: { deletingServerID != nil }, set: { if !$0 { deletingServerID = nil } })) {
            Button("取消", role: .cancel) { deletingServerID = nil }
            Button("删除", role: .destructive) {
                guard let id = deletingServerID else { return }
                deletingServerID = nil
                Task { await PendingNetConnectionWorkflow.deleteServer(id, pairing: vpsPairing, engine: engine, state: state) }
            }
        } message: {
            Text("删除同步的节点记录和访问凭据。若正在连接这台 VPS，将先断开连接；不会卸载服务器。")
        }
        .task {
            await engine.refresh()
            if engine.running && engine.takeover == "local" {
                await state.loadControl()
            } else {
                state.clearLocalControl()
            }
        }
        .sheet(isPresented: $showingPasteImport) {
            PendingPasteImportSheet(busy: vpsPairing.pairing) { text in
                showingPasteImport = false
                Task {
                    await PendingNetConnectionWorkflow.importAndConnect(
                        pasted: text,
                        pairing: vpsPairing,
                        engine: engine,
                        state: state
                    )
                }
            } onCancel: {
                showingPasteImport = false
            }
        }
    }

    // MARK: - One card, one kind of control: pills all the way down

    private var connectionCard: some View {
        PendingConnectionCard {
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
                    await PendingNetConnectionWorkflow.setTakeover(
                        mode, engine: engine, state: state
                    )
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                PendingRouteModePicker(selection: routeMode) { mode in
                    Task {
                        await PendingNetConnectionWorkflow.setRouteMode(
                            mode, engine: engine, state: state
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
        .disabled(engine.connectionBusy || vpsPairing.pairing)
    }

    private var header: some View {
        let needsAuthorization = engine.takeover != "local" && !engine.helperReady
        return PendingConnectionHeader(
            statusText: connectionStatus.0,
            statusKind: connectionStatus.1,
            showsStatus: false,
            action: needsAuthorization
                ? .button(title: "授权后台服务…")
                : .toggle(isOn: engine.running)
        ) { on in
            if needsAuthorization {
                engine.registerHelper()
            } else {
                Task {
                    await PendingNetConnectionWorkflow.setConnected(
                        on, engine: engine, state: state
                    )
                }
            }
        }
    }

    // MARK: - VPS: 竖排列表，选中的那行前面打勾

    private var vpsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                if !vpsPairing.servers.isEmpty {
                    Button(LocalizedStringKey(editingNodes ? "完成" : "编辑")) { editingNodes.toggle() }
                        .buttonStyle(PendingQuietButtonStyle(fill: PendingNetTheme.Palette.surface))
                    Button("测延迟") { testAll() }
                        .buttonStyle(PendingQuietButtonStyle(
                            fill: PendingNetTheme.Palette.surface
                        ))
                        .disabled(latency.busy || vpsPairing.pairing)
                }
                Button("导入") { showingPasteImport = true }
                    .buttonStyle(PendingQuietButtonStyle(
                        fill: PendingNetTheme.Palette.surface
                    ))
                    .disabled(vpsPairing.pairing)
            }

            PendingVPSList(
                items: vpsPairing.servers,
                selectedID: appliedServer?.serverID,
                unpairedIDs: vpsPairing.unpairedServerIDs,
                latencies: latency.results,
                isEditing: editingNodes,
                detailID: $detailServerID,
                onDelete: { deletingServerID = $0 }
            ) { serverID in
                guard !vpsPairing.pairing,
                      let server = vpsPairing.servers.first(where: { $0.serverID == serverID })
                else { return }
                Task {
                    await PendingNetConnectionWorkflow.refreshAndConnect(
                        server: server,
                        pairing: vpsPairing,
                        engine: engine,
                        state: state
                    )
                }
            } onShowDetails: { serverID in
                detailServerID = serverID
            } detailPopover: { server in
                AnyView(serverDetail(server))
            }
        }
    }

    /// 端口、支持的协议、延迟 —— 主界面只放 IP，细节都在这里。
    private func serverDetail(_ server: PairedVPSServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PendingServerNameEditor(name: server.name) { vpsPairing.renameServer(server.serverID, to: $0) }
            PendingVPSDetails(
                server: server,
                nameStyle: .hidden,
                spacing: 10,
                latency: latency.outcome(for: server.serverID)
            )

            PendingNodeSharePanel(server: server)

            Button {
                Task { await measure(server) }
            } label: {
                if latency.isMeasuring(server.serverID) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在测延迟…")
                    }
                } else {
                    Text("测延迟")
                }
            }
            .buttonStyle(PendingQuietButtonStyle())
            .disabled(latency.isMeasuring(server.serverID))
            Button("删除", role: .destructive) { detailServerID = nil; deletingServerID = server.serverID }
                .buttonStyle(.plain).foregroundStyle(PendingNetTheme.Palette.danger)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    /// 逐台测一遍。每台都是同一个测点、同一种算法，测完可以直接横向比较。
    private func testAll() {
        Task { await latency.measureAll(vpsPairing.servers, method: PendingNetLatencyMethod(rawValue: latencyMethod) ?? .tcp) }
    }
    private func measure(_ server: PairedVPSServer) async {
        await latency.measure(server, method: PendingNetLatencyMethod(rawValue: latencyMethod) ?? .tcp)
    }
}
