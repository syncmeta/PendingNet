import SwiftUI

/// 主窗口的分区。放在视图外面，是因为菜单栏和 ⌘, 都要能把主窗口直接切到
/// 「设置」——从前那是另开一个独立设置窗口，两套并存。
enum PendingNetSection: String, CaseIterable, Identifiable {
    case connection
    case live
    case apps
    case domains
    case logs
    case management
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: String(localized: "连接")
        case .live: String(localized: "实时流量")
        case .apps: String(localized: "应用")
        case .domains: String(localized: "域名")
        case .logs: String(localized: "日志")
        case .management: String(localized: "管理")
        case .settings: String(localized: "设置")
        }
    }

    var icon: String {
        switch self {
        case .connection: "point.3.connected.trianglepath.dotted"
        case .live: "waveform.path.ecg"
        case .apps: "square.grid.2x2"
        case .domains: "globe.asia.australia"
        case .logs: "doc.text.magnifyingglass"
        case .management: "server.rack"
        case .settings: "gear"
        }
    }

    var showsTimeRange: Bool {
        switch self {
        case .live, .apps, .domains: true
        case .connection, .logs, .management, .settings: false
        }
    }
}

@MainActor
final class PendingNetNavigation: ObservableObject {
    @Published var section: PendingNetSection? = .connection
}
