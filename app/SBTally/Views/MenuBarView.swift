import SwiftUI
import AppKit
import SBTallyCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var totalUp: Int64 { state.live.reduce(0) { $0 + $1.upRate } }
    private var totalDown: Int64 { state.live.reduce(0) { $0 + $1.downRate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("↑ \(humanBytes(totalUp))/s   ↓ \(humanBytes(totalDown))/s")
                .monospacedDigit()
                .font(.headline)
            Divider()
            if state.live.isEmpty {
                Text("No live traffic").foregroundStyle(.secondary)
            } else {
                ForEach(state.live.prefix(5)) { g in
                    Text("\(g.app) — ↓\(humanBytes(g.downRate))/s ↑\(humanBytes(g.upRate))/s")
                        .monospacedDigit()
                }
            }
            Divider()
            Button("Open Dashboard") { openWindow(id: "main") }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
        .frame(width: 280)
    }
}
