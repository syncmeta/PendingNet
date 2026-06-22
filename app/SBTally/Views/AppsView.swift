import SwiftUI
import SBTallyCore

struct AppsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.apps) {
            TableColumn("App", value: \.app)
            TableColumn("Up") { Text(humanBytes($0.upload)).monospacedDigit() }
            TableColumn("Down") { Text(humanBytes($0.download)).monospacedDigit() }
            TableColumn("Total") { Text(humanBytes($0.total)).monospacedDigit() }
        }
    }
}
