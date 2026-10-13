import SBTallyCore
import SwiftUI

/// 设置页。端口 / 规则集 / 更新与 iOS 侧共用组件；“开机自启”和 Sparkle
/// 更新控件只属于 macOS。
struct SettingsView: View {
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var startup: PendingNetStartupController

    @State private var engineVersion: String?
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var vpsPairing: VPSPairingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                startupCard
                PendingLanguageRow()
                PendingLatencyMethodRow()
                if let choice = protocolChoice {
                    PendingProtocolPicker(members: choice.members, selectorTag: choice.selectorTag, selected: choice.selected) { name in
                        Task {
                            if engine.running {
                                if engine.takeover == "local" {
                                    if await state.select(selector: choice.selectorTag, name: name) { engine.rememberProtocol(name) }
                                } else { await engine.selectProtocol(selector: choice.selectorTag, name: name) }
                            } else { engine.rememberProtocol(name) }
                        }
                    }.disabled(engine.connectionBusy)
                }
                PendingLocalInboundCard(
                    listenAddress: engine.localListenAddress,
                    port: engine.localProxyPort,
                    allowsLAN: engine.allowsLAN,
                    reservedPort: PendingNetUserEngine.controlPort,
                    save: { port, allowLAN in
                        await engine.setLocalInbound(port: port, allowLAN: allowLAN)
                    }
                )
                PendingRuleSetCard(
                    items: PendingNetTunnelConfig.requiredRuleSetNames.map {
                        PendingRuleSetItem(name: $0, ready: engine.ruleSetPresence[$0] ?? false)
                    },
                    refresh: { await engine.refreshRuleSets() }
                )
                updateCard
            }
            .padding(PendingNetTheme.Metrics.gutter)
            .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .task {
            engineVersion = await PendingNetEngineBinary.bundledVersion()
            startup.refresh()
            engine.refreshRuleSetPresence()
            if engine.configuredProtocols == nil {
                let selected = PendingNetSelectorPreferences().selections["proxy"]
                if let server = vpsPairing.servers.first(where: { PendingNetRuntimeServer.selectorTag(forServerID: $0.serverID) == selected }) ?? vpsPairing.servers.first,
                   let runtime = await vpsPairing.runtimeServer(for: server) { engine.prepareProtocolChoices(runtime) }
            }
        }
    }

    private var protocolChoice: PendingNetProtocolSelection? {
        if engine.running, let selector = engine.takeover == "local" ? state.proxies["proxy"]?.now : engine.activeSelectorTag,
           let proxy = engine.takeover == "local" ? state.proxies[selector] : engine.protocolProxy, let members = proxy.all {
            return PendingNetProtocolSelection(selectorTag: selector, members: members, selected: proxy.now)
        }
        return engine.configuredProtocols
    }

    private var startupCard: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("开机自启", isOn: Binding(
                    get: { startup.startsAtLogin },
                    set: { enabled in
                        if enabled { engine.rememberCurrentConnectionForNextLaunch() }
                        startup.setStartsAtLogin(enabled)
                    }
                ))
                .toggleStyle(.switch)
                .tint(PendingNetTheme.Palette.accent)
                .font(PendingNetTheme.Fonts.body)
                .foregroundStyle(PendingNetTheme.Palette.ink)

                if let error = startup.lastError {
                    Text(error)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(startup.requiresApproval
                            ? PendingNetTheme.Palette.inkMuted
                            : PendingNetTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var updateCard: some View {
        PendingUpdateCard(version: updater.currentVersion, engineVersion: engineVersion) {
            Button("检查更新…") { updater.checkForUpdates() }
                .buttonStyle(.borderless)
                .disabled(!updater.canCheckForUpdates)
        } extra: {
            if updater.isConfigured {
                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .toggleStyle(.switch)
                Toggle("有更新时后台下载好", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }
                ))
                .toggleStyle(.switch)
                .disabled(!updater.automaticallyChecksForUpdates)
            } else {
                Text("更新发布地址尚未配置")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            }
        }
    }
}
