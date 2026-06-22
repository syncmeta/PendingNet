import SwiftUI
import SBTallyCore

@main
struct SBTallyApp: App {
    @StateObject private var state = AppState(
        provider: APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!))

    var body: some Scene {
        Window("sbtally", id: "main") {
            DashboardView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 440)
                .task {
                    await state.refresh()
                    state.startLive()
                }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}
