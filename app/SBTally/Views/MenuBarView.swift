import SwiftUI
import AppKit
import SBTallyCore

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var vpsPairing: VPSPairingController
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

    private func protocolLabel(_ tag: String) -> String {
        guard let selector = appliedSelectorTag, tag.hasPrefix(selector + "-") else { return tag }
        return String(tag.dropFirst(selector.count + 1))
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
            if !vpsPairing.servers.isEmpty {
                PendingPillPicker(
                    options: vpsPairing.servers.map { .init($0.serverID, $0.address) },
                    selection: appliedServer?.serverID
                ) { serverID in
                    guard let server = vpsPairing.servers.first(where: { $0.serverID == serverID }),
                          server.serverID != appliedServer?.serverID,
                          !vpsPairing.pairing else { return }
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
            if let all = protoProxy?.all, let selector = appliedSelectorTag {
                PendingPillPicker(
                    options: all.map { .init($0, protocolLabel($0)) },
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
                Button("打开主窗口") { openWindow(id: "main") }
                    .buttonStyle(PendingQuietButtonStyle())
                Button("检查更新") { updater.checkForUpdates() }
                    .buttonStyle(.plain)
                    .disabled(!updater.canCheckForUpdates)
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
