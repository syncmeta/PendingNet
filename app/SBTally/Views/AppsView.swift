import SwiftUI
import SBTallyCore

struct AppsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PendingPageHeader(
                title: "应用",
                subtitle: "按应用查看所选时间范围内的流量。"
            )
            .padding(.horizontal, PendingNetTheme.Metrics.gutter)
            .padding(.top, PendingNetTheme.Metrics.gutter)

            Table(state.apps) {
                TableColumn("应用", value: \.app)
                TableColumn("上传") { Text(humanBytes($0.upload)).monospacedDigit() }
                TableColumn("下载") { Text(humanBytes($0.download)).monospacedDigit() }
                TableColumn("总计") { Text(humanBytes($0.total)).monospacedDigit() }
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
                if state.apps.isEmpty {
                    PendingEmptyState(
                        icon: "square.grid.2x2",
                        title: state.lastError == nil ? "还没有应用数据" : "统计服务尚未启用",
                        detail: state.lastError == nil ? "选定时间内的应用流量会显示在这里。" : "代理仍可正常使用；启用统计服务后这里会显示应用统计。"
                    )
                }
            }
        }
        .background(PendingNetTheme.Palette.canvas)
    }
}
