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
                    PendingEmptyState(
                        icon: state.lastError == nil ? "waveform.path.ecg" : "chart.bar.xaxis",
                        title: state.lastError == nil ? "暂时没有流量" : "统计服务尚未启用",
                        detail: state.lastError == nil ? "出现新连接后会自动显示在这里。" : "代理仍可正常使用；启用统计服务后这里会显示实时数据。"
                    )
                }
            }
        }
        .background(PendingNetTheme.Palette.canvas)
    }
}
