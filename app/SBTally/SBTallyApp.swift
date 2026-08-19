import AppKit
import SwiftUI
import SBTallyCore

@main
struct SBTallyApp: App {
    @StateObject private var state: AppState
    @StateObject private var engine: EngineController
    @StateObject private var vpsPairing: VPSPairingController
    @StateObject private var updater = PendingNetUpdateController()
    @StateObject private var navigation = PendingNetNavigation()
    @Environment(\.openWindow) private var openWindow

    /// 每个 controller 都在自己的 init 里读 `UserDefaults`，所以旧域的搬迁必须
    /// 赶在它们被构造出来之前跑完 —— 晚一步，读到的就是空的新域，用户的端口和
    /// 已配对 VPS 看上去就像被升级抹掉了。这也是这些 `@StateObject` 不写默认值、
    /// 改成在 init 里显式赋值的唯一原因。
    init() {
        let legacyServers = PendingNetLegacyDefaultsMigration.run()
        _state = StateObject(wrappedValue: AppState(provider: PendingNetLocalAPIProvider()))
        _engine = StateObject(wrappedValue: EngineController())
        _vpsPairing = StateObject(
            wrappedValue: VPSPairingController(legacyServers: legacyServers))
    }

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
                    // 记住的路由模式要在这里主动推一次，不能等用户再点一遍：
                    // 后台服务那份配置的 default_mode 是白名单，而界面显示的是
                    // 记住的那一档 —— 不推的话，一进 TUN 就是「界面亮全局、引擎
                    // 走白名单」，比切不动更糟。`refresh()` 刚认过接管方式，所以
                    // 顺序不能反。
                    await PendingNetRoutingWorkflow.applyRemembered(engine: engine, state: state)
                    vpsPairing.refreshFromCloud()
                }
                // 回到前台顺手拉一次 iCloud —— 在 iPhone 上配好的 VPS 不用重开
                // App 就能出现在列表里。iCloud 用不了时这是空操作。
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    vpsPairing.refreshFromCloud()
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
            // 用 PendingNet 的应用图标（PendingNetMenuBarIcon，明暗两套变体），
            // 不再用 SF Symbol 的 network 图标。停止时半透明，保留一眼可辨的连接状态。
            Image("PendingNetMenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .opacity(engine.running ? 1.0 : 0.5)
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
