import SwiftUI
import AppKit
import SBTallyCore

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var vpsPairing: VPSPairingController
    @EnvironmentObject private var navigation: PendingNetNavigation
    @Environment(\.openWindow) private var openWindow

    private var totalUp: Int64 { state.live.reduce(0) { $0 + $1.upRate } }
    private var totalDown: Int64 { state.live.reduce(0) { $0 + $1.downRate } }

    private var appliedSelectorTag: String? {
        engine.takeover == "local" ? state.proxies["proxy"]?.now : engine.activeSelectorTag
    }

    private var appliedServer: PairedVPSServer? {
        guard let tag = appliedSelectorTag else { return nil }
        return vpsPairing.servers.first {
            PendingNetRuntimeServer.selectorTag(forServerID: $0.serverID) == tag
        }
    }

    private var protoProxy: Proxy? {
        guard appliedServer != nil, let tag = appliedSelectorTag else { return nil }
        return state.proxies[tag]
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                // 这里不再放 PendingNet 字样与图标 -- 菜单栏图标本身就是品牌标识，
                // 框里只留连接状态药丸，避免重复。
                PendingStatusPill(
                    text: engine.connectionBusy ? "正在切换" : (engine.running ? "已连接" : (engine.takeover == "local" || engine.helperReady ? "已停止" : "等待授权")),
                    kind: engine.connectionBusy ? .neutral : (engine.running ? .success : .neutral)
                )
                Spacer()
            }

            if engine.takeover != "local" && !engine.helperReady {
                Button("授权后台服务…") { engine.registerHelper() }
                    .buttonStyle(PendingPrimaryButtonStyle())
                    .disabled(engine.connectionBusy || vpsPairing.pairing)
            } else {
                Toggle(engine.running ? "已连接" : "已停止", isOn: Binding(
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
                .disabled(engine.connectionBusy || vpsPairing.pairing)
            }

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
            .disabled(engine.connectionBusy || vpsPairing.pairing)

            // 档位名不在这里另写一遍：三个中文名跟主窗口共用同一个选择器，
            // Clash 那边的写法只由 `clashName` / `clashNamed` 翻译。
            PendingRouteModePicker(
                selection: PendingNetRouteMode.clashNamed(state.mode)
            ) { mode in
                Task {
                    await PendingNetConnectionWorkflow.setRouteMode(
                        mode, engine: engine, state: state
                    )
                }
            }
            .disabled(engine.connectionBusy || vpsPairing.pairing)
            if let note = state.modeNote {
                Text(note)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VPS 和主窗口一致：竖排列表，选中的那行前面打勾。
            ForEach(vpsPairing.servers) { server in
                let selected = server.serverID == appliedServer?.serverID
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PendingNetTheme.Palette.accent)
                        .opacity(selected ? 1 : 0)
                        .frame(width: 12)
                    // verbatim: 地址是标识符，不能被本地化
                    Text(verbatim: server.address)
                        .font(selected
                            ? PendingNetTheme.Fonts.bodyEmphasized.monospaced()
                            : PendingNetTheme.Fonts.body.monospaced())
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !selected, !vpsPairing.pairing, !engine.connectionBusy else { return }
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
            // 菜单栏这一版不带小标题（这里每一排都没有），但名字和主窗口
            // 走的是同一份 `PendingNetOutboundNaming`。
            if let all = protoProxy?.all, let selector = appliedSelectorTag {
                PendingPillPicker(
                    options: all.map {
                        .init($0, PendingNetOutboundNaming.title(
                            forMemberTag: $0,
                            selectorTag: selector
                        ))
                    },
                    selection: protoProxy?.now
                ) { name in
                    Task { await state.select(selector: selector, name: name) }
                }
                .disabled(engine.connectionBusy || vpsPairing.pairing)
            }
            // 引擎错误不再写在这里常驻：菜单栏根上挂了 toast（见 SBTallyApp），
            // 失败时弹一下自动消失。下面只留失败时的运行日志（折叠态），它是
            // 诊断用的，不是要用户一直盯着读的报错。
            if engine.startFailed && !engine.logTail.isEmpty {
                ScrollView {
                    Text(engine.logTail)
                        .font(PendingNetTheme.Fonts.caption.monospaced())
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Divider().overlay(PendingNetTheme.Palette.hairline)

            Text("↑ \(humanBytes(totalUp))/秒   ↓ \(humanBytes(totalDown))/秒")
                .monospacedDigit()
                .font(PendingNetTheme.Fonts.bodyEmphasized)
                .foregroundStyle(PendingNetTheme.Palette.ink)
            if state.live.isEmpty {
                Text("暂无实时流量")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            } else {
                ForEach(state.live.prefix(5)) { g in
                    Text("\(g.app) · ↓\(humanBytes(g.downRate))/秒 ↑\(humanBytes(g.upRate))/秒")
                        .monospacedDigit()
                        .font(PendingNetTheme.Fonts.caption)
                }
            }

            Divider().overlay(PendingNetTheme.Palette.hairline)
            HStack {
                Button("打开主窗口") {
                    navigation.section = .connection
                    openWindow(id: "main")
                }
                .buttonStyle(PendingQuietButtonStyle())
                // 设置就是主窗口里的那一栏，不再另开一个设置窗口。
                Button("设置") {
                    navigation.section = .settings
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .font(PendingNetTheme.Fonts.chrome)
                .foregroundStyle(PendingNetTheme.Palette.ink)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(PendingNetTheme.Fonts.chrome)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(PendingNetTheme.Palette.canvas)
        .task {
            await engine.refresh()
            if engine.running && engine.takeover == "local" {
                await state.loadControl()
            } else {
                state.clearLocalControl()
            }
        }
    }
}
