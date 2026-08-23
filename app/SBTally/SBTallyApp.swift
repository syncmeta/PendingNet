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
    /// 短暂浮层提示。错误 / 成功消息不再常驻在卡片里，改成弹一下自动消失--
    /// 否则一条一次性的报错会一直挂在界面上，问题修好了也还在。
    @StateObject private var toast = PendingToastCenter()
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
                .environmentObject(toast)
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
                // 双击一份 .pdn，或者点一条 pendingnet:// 配对链接 —— 两条
                // 路进来的都走同一条配对流程，认不出来的 URL 一律不理。
                .onOpenURL { url in
                    Task {
                        await PendingNetConnectionWorkflow.importAndConnect(
                            opened: url,
                            pairing: vpsPairing,
                            engine: engine,
                            state: state
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    engine.stopBeforeTermination()
                }
                // 错误改成 toast 弹出，不再写进卡片常驻。在主窗口根上观察：不论
                // 当前停在连接 / 实时 / 设置哪个分区，引擎或配对失败都能弹到用户
                // 面前，然后自己消失。`nil` 是被成功路径清掉的，忽略即可。
                .onChange(of: engine.lastError) { _, _ in
                    if let text = engine.friendlyErrorText() { toast.show(text) }
                }
                .onChange(of: vpsPairing.lastError) { _, value in
                    if let value { toast.show(value) }
                }
                .overlay(alignment: .top) {
                    PendingToastOverlay(center: toast)
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
                .environmentObject(toast)
                // 主窗口关掉时，菜单栏是唯一在场的入口；引擎失败也得在这里
                // 弹出来，不能因为主窗口没开就静默。
                .onChange(of: engine.lastError) { _, _ in
                    if let text = engine.friendlyErrorText() { toast.show(text) }
                }
                .overlay(alignment: .top) {
                    PendingToastOverlay(center: toast)
                }
        } label: {
            // 用 PendingNet 的应用图标（PendingNetMenuBarIcon，明暗两套变体），
            // 不再用 SF Symbol 的 network 图标。停止时半透明，保留一眼可辨的连接状态。
            //
            // 这里**不要**加 `.resizable()` / `.frame()`：`MenuBarExtra` 的 label
            // 只取原样的 Image 去做状态栏项，布局修饰符会被丢掉。0.3.29 就是这么
            // 修错过一次 —— 加了 `.frame(width: 22, height: 18)`，装上去菜单栏照样
            // 被一个图标占满。尺寸只能由资源的固有尺寸决定，所以
            // PendingNetMenuBarIcon 现在按 22×18 点出 @1x/@2x/@3x 三份
            // （见 scripts/make-menubar-icon.py）。改图标时别再退回单张大图。
            //
            // `.opacity` 同理可能被丢掉，留着是因为它生效时更好、失效也不比现状差。
            Image("PendingNetMenuBarIcon")
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
