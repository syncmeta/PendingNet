import SwiftUI
import SBTallyCore

@main
struct SBTallyApp: App {
    @StateObject private var state = AppState(
        provider: APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!))
    @StateObject private var engine = EngineController()

    var body: some Scene {
        Window("PendingNet", id: "main") {
            DashboardView()
                .environmentObject(state)
                .environmentObject(engine)
                .frame(minWidth: 680, minHeight: 440)
                .task {
                    await state.refresh()
                    state.startLive()
                    await engine.refresh()
                }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(engine)
        } label: {
            Image(systemName: "network")
        }
        .menuBarExtraStyle(.window)
    }
}
