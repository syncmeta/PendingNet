import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: PendingNetNavigation

    private var destination: PendingNetSection { navigation.section ?? .connection }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(PendingNetSection.allCases, selection: $navigation.section) { item in
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
