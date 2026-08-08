import SBTallyCore
import SwiftUI

/// 设置页。macOS 那边这一栏是「端口 / 规则集 / 更新」三块卡；iOS 上只有
/// 规则集是真有对应物：
///
/// - 端口与「允许局域网访问」：iOS 的 Packet Tunnel 不对外开监听端口，
///   没有可改的东西，做一个点不动的开关只会误导；
/// - 更新：iOS 不走 Sparkle，装新版由 Xcode/TestFlight 那条路负责。
///
/// 所以这里是「规则集 + 关于」两块，卡片样式与 macOS 同一套。
struct PendingNetIOSSettingsView: View {
    @EnvironmentObject private var controller: PendingNetIOSController
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ruleSetCard
                    aboutCard
                }
                .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("设置")
            .toolbarBackground(PendingNetTheme.Palette.canvas, for: .navigationBar)
            .tint(PendingNetTheme.Palette.accent)
        }
    }

    private var ruleSetCard: some View {
        PendingSectionCard("规则集") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("白名单 / 黑名单所需的 geoip / geosite 数据")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    PendingStatusPill(
                        text: controller.ruleSetStore.isReady ? "已就绪" : "未下载",
                        kind: controller.ruleSetStore.isReady ? .success : .neutral
                    )
                }

                Text("「白名单」靠它判断哪些流量直连，「黑名单」靠它判断哪些流量走代理。没有的话切到这两档会自动降级成全局。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 7) {
                        if refreshing {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                        } else {
                            Text(controller.ruleSetStore.isReady ? "重新下载" : "下载")
                        }
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(refreshing)

                if let message {
                    Text(message)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aboutCard: some View {
        PendingSectionCard("关于") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("版本", Self.versionText)
                if let server = controller.server {
                    infoRow("当前 VPS", server.name)
                }
                infoRow("已配对", "\(controller.servers.count) 台")
            }
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

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            Spacer()
            // verbatim: 版本号/台数是标识符，不该被本地化成千分位
            Text(verbatim: value)
                .font(PendingNetTheme.Fonts.caption.monospaced())
                .foregroundStyle(PendingNetTheme.Palette.ink)
        }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        message = nil
        errorMessage = nil
        do {
            try await controller.ruleSetStore.refresh()
            message = "规则集已更新"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
