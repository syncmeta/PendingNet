import SwiftUI
import SBTallyCore

struct DomainsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.domains) {
            TableColumn("Host", value: \.host)
            TableColumn("Up") { Text(humanBytes($0.upload)).monospacedDigit() }
            TableColumn("Down") { Text(humanBytes($0.download)).monospacedDigit() }
            TableColumn("Total") { Text(humanBytes($0.total)).monospacedDigit() }
        }
    }
}
