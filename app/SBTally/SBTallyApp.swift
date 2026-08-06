import AppKit
import SwiftUI
import SBTallyCore

@main
struct SBTallyApp: App {
    @StateObject private var state = AppState(
        provider: PendingNetLocalAPIProvider())
    @StateObject private var engine = EngineController()
    @StateObject private var vpsPairing = VPSPairingController()
    @StateObject private var updater = PendingNetUpdateController()

    var body: some Scene {
        Window("PendingNet", id: "main") {
            DashboardView()
                .environmentObject(state)
                .environmentObject(engine)
                .environmentObject(vpsPairing)
                .environmentObject(updater)
                .frame(minWidth: 820, minHeight: 560)
                .background(PendingNetTheme.Palette.canvas)
                .task {
                    await state.refresh()
                    state.startLive()
                    await engine.refresh()
                }
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "pdn" else { return }
                    Task {
                        await PendingNetConnectionWorkflow.importAndConnect(
                            url: url,
                            pairing: vpsPairing,
                            engine: engine,
                            state: state
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    engine.stopBeforeTermination()
                }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(engine)
                .environmentObject(vpsPairing)
                .environmentObject(updater)
        } label: {
            Image(systemName: engine.running ? "network" : "network.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(engine.running ? .primary : .secondary)
        }
        .menuBarExtraStyle(.window)

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("应用更新")
                    .font(.headline)
                Text("当前版本 \(updater.currentVersion)")
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .padding(20)
            .frame(width: 340)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
