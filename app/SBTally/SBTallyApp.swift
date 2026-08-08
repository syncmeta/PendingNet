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
    @StateObject private var navigation = PendingNetNavigation()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("PendingNet", id: "main") {
            DashboardView()
                .environmentObject(state)
                .environmentObject(engine)
                .environmentObject(vpsPairing)
                .environmentObject(updater)
                .environmentObject(navigation)
                // 内容并成一张卡之后不需要那么宽；最小值仍留足侧栏 + 一排药丸
                // 不被截断的余量。
                .frame(minWidth: 640, minHeight: 440)
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
        .defaultSize(width: 720, height: 500)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(engine)
                .environmentObject(vpsPairing)
                .environmentObject(updater)
                .environmentObject(navigation)
        } label: {
            Image(systemName: engine.running ? "network" : "network.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(engine.running ? .primary : .secondary)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // 设置就是主窗口里的那个分区，没有第二个设置窗口。⌘, 也走这条。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    openWindow(id: "main")
                    navigation.section = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
