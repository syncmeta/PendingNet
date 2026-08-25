import SwiftUI
import SBTallyCore

struct LiveView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PendingPageHeader(title: "实时流量")
            .padding(.horizontal, PendingNetTheme.Metrics.gutter)
            .padding(.top, PendingNetTheme.Metrics.gutter)

            Table(state.live) {
                TableColumn("应用", value: \.app)
                TableColumn("上传") { Text(humanBytes($0.upRate) + "/秒").monospacedDigit() }
                TableColumn("下载") { Text(humanBytes($0.downRate) + "/秒").monospacedDigit() }
                TableColumn("连接数") { Text(String($0.conns)).monospacedDigit() }
                TableColumn("主要域名", value: \.topHost)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .background(PendingNetTheme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                    .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, PendingNetTheme.Metrics.gutter)
            .padding(.bottom, PendingNetTheme.Metrics.gutter)
            .overlay {
                if state.live.isEmpty {
                    StatsEmptyStateView(subject: "实时流量")
                }
            }
        }
        .background(PendingNetTheme.Palette.canvas)
    }
}
