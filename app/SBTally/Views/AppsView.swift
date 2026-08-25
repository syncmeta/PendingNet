import SwiftUI
import SBTallyCore

struct AppsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PendingPageHeader(title: "应用")
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
                    StatsEmptyStateView(subject: "应用流量")
                }
            }
        }
        .background(PendingNetTheme.Palette.canvas)
    }
}
