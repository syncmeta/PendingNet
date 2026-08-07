import SwiftUI
import SBTallyCore

struct DomainsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PendingPageHeader(title: "域名")
            .padding(.horizontal, PendingNetTheme.Metrics.gutter)
            .padding(.top, PendingNetTheme.Metrics.gutter)

            Table(state.domains) {
                TableColumn("域名", value: \.host)
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
                if state.domains.isEmpty {
                    PendingEmptyState(
                        icon: "globe.asia.australia",
                        title: state.lastError == nil ? "还没有域名数据" : "统计服务尚未启用",
                        detail: state.lastError == nil ? "选定时间内的域名流量会显示在这里。" : "代理仍可正常使用；启用统计服务后这里会显示域名统计。"
                    )
                }
            }
        }
        .background(PendingNetTheme.Palette.canvas)
    }
}
