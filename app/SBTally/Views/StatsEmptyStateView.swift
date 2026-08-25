import SwiftUI
import SBTallyCore

/// 统计页面空着的时候说什么。
///
/// 从前三个页面各写各的，条件都是「读统计接口失败了没有」，于是不管什么原因
/// 都落到同一句「统计服务尚未启用」—— 那句话既不解释为什么，也不给下一步，
/// 而且界面上根本没有地方能「启用」它。现在成因分三种，措辞和图标都跟着走。
struct StatsEmptyStateView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController

    /// 这个页面在说什么，例如「应用流量」「域名」。
    let subject: String

    private var availability: PendingNetStatsService.Availability {
        PendingNetStatsService.availability(
            engineRunning: engine.running,
            daemon: engine.statsDaemon,
            hasData: false,
            readFailed: state.statsError != nil
        )
    }

    var body: some View {
        let message = PendingNetStatsService.emptyMessage(for: availability, subject: subject)
        PendingEmptyState(icon: icon, title: message.title, detail: message.detail)
    }

    private var icon: String {
        switch availability {
        case .ready, .noTraffic: "waveform.path.ecg"
        case .engineStopped: "bolt.horizontal.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}
