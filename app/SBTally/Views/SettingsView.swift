import SBTallyCore
import SwiftUI

/// 设置页。端口 / 规则集 / 更新与 iOS 侧共用组件；“开机自启”和 Sparkle
/// 更新控件只属于 macOS。
struct SettingsView: View {
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var startup: PendingNetStartupController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PendingPageHeader(title: "设置")
                startupCard
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
            startup.refresh()
            engine.refreshRuleSetPresence()
        }
    }

    private var startupCard: some View {
        PendingSectionCard("启动") {
            VStack(alignment: .leading, spacing: 8) {
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

                Text("打开后，登录时恢复上次留下的连接开关、接管方式、路由、VPS 和协议。上次关着就保持关闭。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

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
        PendingUpdateCard(version: updater.currentVersion) {
            Button("检查更新…") { updater.checkForUpdates() }
                .buttonStyle(PendingQuietButtonStyle())
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
