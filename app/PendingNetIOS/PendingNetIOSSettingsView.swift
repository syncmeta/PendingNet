import SBTallyCore
import SwiftUI

/// 设置页。三张卡——端口 / 规则集 / 更新——与 macOS 侧同一套组件、同一个
/// 顺序（见 `app/PendingUI/PendingSettingsViews.swift`）。
///
/// 手机上少掉的只有 Sparkle 那几个控件：「自动检查更新」「有更新时后台下载
/// 好」以及「检查更新…」按钮。iOS 不走 Sparkle，App 自己没有任何检查更新的
/// 能力，装新版从 TestFlight / App Store 来——摆一个点了没反应的按钮比不摆
/// 更糟。其余一字不差，包括「端口」和「允许局域网访问」：那两个在这里是真
/// 开关，落到隧道里那个本机混合入站上（见 `PendingNetTunnelController`）。
struct PendingNetIOSSettingsView: View {
    @EnvironmentObject private var controller: PendingNetIOSController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PendingLocalInboundCard(
                        listenAddress: controller.tunnel.localInbound.listenAddress,
                        port: controller.tunnel.localInbound.port,
                        allowsLAN: controller.tunnel.localInbound.allowsLAN,
                        isLive: controller.tunnel.isTunnelLive,
                        // 隧道里没有 clash_api，控制通道走 App Group 里的 unix
                        // socket，没有哪个端口需要被保留。
                        reservedPort: nil,
                        save: { port, allowLAN in
                            await controller.setLocalInbound(port: port, allowLAN: allowLAN)
                        }
                    )
                    PendingRuleSetCard(
                        items: PendingNetTunnelConfig.requiredRuleSetNames.map {
                            PendingRuleSetItem(
                                name: $0,
                                ready: controller.ruleSetStore.presence[$0] ?? false
                            )
                        },
                        refresh: {
                            do {
                                try await controller.ruleSetStore.refresh()
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }
                    )
                    PendingUpdateCard(version: Self.versionText) {
                        EmptyView()
                    } extra: {
                        Text("iPhone 版由 TestFlight / App Store 更新，App 自己不检查。")
                            .font(PendingNetTheme.Fonts.caption)
                            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("设置")
            .toolbarBackground(PendingNetTheme.Palette.canvas, for: .navigationBar)
            .tint(PendingNetTheme.Palette.accent)
        }
    }

    /// 版本号来自打包时写进 Info.plist 的 MARKETING_VERSION / build，
    /// 不在代码里另写一份——两处对不上就会变成排查装了哪一版的噪音。
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
