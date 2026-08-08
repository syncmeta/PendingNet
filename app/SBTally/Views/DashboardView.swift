import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Destination? = .connection

    private enum Destination: String, CaseIterable, Identifiable {
        case connection
        case live
        case apps
        case domains
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connection: "连接"
            case .live: "实时流量"
            case .apps: "应用"
            case .domains: "域名"
            case .settings: "设置"
            }
        }

        var icon: String {
            switch self {
            case .connection: "point.3.connected.trianglepath.dotted"
            case .live: "waveform.path.ecg"
            case .apps: "square.grid.2x2"
            case .domains: "globe.asia.australia"
            case .settings: "gear"
            }
        }

        var showsTimeRange: Bool { self != .connection && self != .settings }
    }

    private var destination: Destination { selection ?? .connection }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(Destination.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.icon)
                        .font(PendingNetTheme.Fonts.chrome)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(PendingNetTheme.Palette.canvas)
            .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 224)
        } detail: {
            detail
                .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
                .toolbar {
                    if destination.showsTimeRange {
                        ToolbarItemGroup(placement: .automatic) {
                            Picker("统计范围", selection: $state.since) {
                                Text("1 小时").tag("1h")
                                Text("24 小时").tag("24h")
                                Text("7 天").tag("7d")
                                Text("30 天").tag("30d")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 276)

                            Button {
                                Task { await state.refresh() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .help("刷新统计")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(PendingNetTheme.Palette.accent)
        .onChange(of: state.since) {
            Task { await state.refresh() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .connection:
            ControlView()
        case .live:
            LiveView()
        case .apps:
            AppsView()
        case .domains:
            DomainsView()
        case .settings:
            SettingsView()
        }
    }
}
