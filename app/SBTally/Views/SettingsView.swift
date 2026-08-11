import SBTallyCore
import SwiftUI

/// 设置页。三张卡——端口 / 规则集 / 更新——与 iOS 侧同一套组件、同一个顺序
/// （见 `app/PendingUI/PendingSettingsViews.swift`）。这一端多出来的只有
/// Sparkle 那几个控件：iOS 不走 Sparkle。
struct SettingsView: View {
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PendingPageHeader(title: "设置")
                PendingLocalInboundCard(
                    listenAddress: engine.localListenAddress,
                    port: engine.localProxyPort,
                    allowsLAN: engine.allowsLAN,
                    isLive: engine.running,
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
        .task { engine.refreshRuleSetPresence() }
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
