import SwiftUI
import SBTallyCore

struct LiveView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.live) {
            TableColumn("App", value: \.app)
            TableColumn("↑/s") { Text(humanBytes($0.upRate) + "/s").monospacedDigit() }
            TableColumn("↓/s") { Text(humanBytes($0.downRate) + "/s").monospacedDigit() }
            TableColumn("Conns") { Text(String($0.conns)).monospacedDigit() }
            TableColumn("Top host", value: \.topHost)
        }
        .overlay {
            if state.live.isEmpty {
                ContentUnavailableView("No live traffic", systemImage: "wifi",
                                       description: Text("Waiting for the daemon's live feed…"))
            }
        }
    }
}
