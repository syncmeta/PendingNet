import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            LiveView().tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
            AppsView().tabItem { Label("Apps", systemImage: "app.badge") }
            DomainsView().tabItem { Label("Domains", systemImage: "globe") }
            ControlView().tabItem { Label("Control", systemImage: "slider.horizontal.3") }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Since", selection: $state.since) {
                    Text("1h").tag("1h")
                    Text("24h").tag("24h")
                    Text("7d").tag("7d")
                    Text("30d").tag("30d")
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onChange(of: state.since) {
            Task { await state.refresh() }
        }
        .navigationTitle("sbtally")
    }
}
