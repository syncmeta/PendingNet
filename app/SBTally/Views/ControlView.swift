import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct ControlView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    /// 每台 VPS 一个延迟数，语义和 iOS 那边完全一样（见
    /// `PendingNetLatencyTarget`）：到这台 VPS 代理入口的 TCP 握手往返时间。
    @StateObject private var latency = PendingNetLatencyTester()

    @State private var showingPairingImporter = false
    @State private var showingPasteImport = false
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

    private var connectionStatus: (String, PendingStatusPill.Kind) {
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
        .task {
            await engine.refresh()
            if engine.running {
                await state.loadControl()
            } else {
                state.clearControlForStoppedEngine()
            }
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
                    await engine.setTakeover(mode)
                    await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                PendingRouteModePicker(selection: routeMode) { mode in
                    Task {
                        await PendingNetRoutingWorkflow.select(
                            mode: mode.clashName,
                            engine: engine,
                            state: state
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
                PendingProtocolPicker(
                    members: all,
                    selectorTag: selector,
                    selected: protoProxy?.now
                ) { name in
                    Task { await state.select(selector: selector, name: name) }
                }
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

    private var header: some View {
        let needsAuthorization = engine.takeover != "local" && !engine.helperReady
        return PendingConnectionHeader(
            statusText: connectionStatus.0,
            statusKind: connectionStatus.1,
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
                    Button("测延迟") { testAll() }
                        .buttonStyle(PendingQuietButtonStyle(
                            fill: PendingNetTheme.Palette.surface
                        ))
                        .disabled(latency.busy || vpsPairing.pairing)
                }
                Button("粘贴链接") { showingPasteImport = true }
                    .buttonStyle(PendingQuietButtonStyle(
                        fill: PendingNetTheme.Palette.surface
                    ))
                    .disabled(vpsPairing.pairing)
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
                detailID: $detailServerID
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
            PendingVPSDetails(
                server: server,
                nameStyle: .heading,
                spacing: 10,
                latency: latency.outcome(for: server.serverID)
            )

            Button {
                Task { await latency.measure(server) }
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
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    /// 逐台测一遍。每台都是同一个测点、同一种算法，测完可以直接横向比较。
    private func testAll() {
        Task { await latency.measureAll(vpsPairing.servers) }
    }

}
