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

    private var appliedSelectorTag: String? { state.proxies["proxy"]?.now }

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
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PendingNetTheme.Palette.accentBackground)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(PendingNetTheme.Palette.accent)
                }
                .frame(width: 32, height: 32)
                Text("PendingNet")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                Spacer()
                PendingStatusPill(
                    text: engine.running ? "已连接" : (engine.takeover == "local" || engine.helperReady ? "已停止" : "等待授权"),
                    kind: engine.running ? .success : .neutral
                )
            }

            if engine.takeover != "local" && !engine.helperReady {
                Button("授权后台服务…") { engine.registerHelper() }
                    .buttonStyle(PendingPrimaryButtonStyle())
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
                    await engine.setTakeover(mode)
                    await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
                }
            }

            PendingPillPicker(
                options: [
                    .init("Global", "全局"),
                    .init("Whitelist", "白名单"),
                    .init("Blacklist", "黑名单"),
                ],
                selection: state.mode
            ) { mode in
                Task {
                    await PendingNetRoutingWorkflow.select(mode: mode, engine: engine, state: state)
                }
            }
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
            }
            if let error = engine.lastError {
                Text(error)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.danger)
            }
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
            await state.loadControl()
        }
    }
}
