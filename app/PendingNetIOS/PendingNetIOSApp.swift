import SBTallyCore
import SwiftUI

@main
struct PendingNetIOSApp: App {
    @StateObject private var controller = PendingNetIOSController()
    /// 短暂浮层提示。错误 / 成功消息不再常驻在卡片里，改成弹一下自动消失--
    /// 否则一条一次性的报错会一直挂在界面上，问题修好了也还在。
    @StateObject private var toast = PendingToastCenter()
    @StateObject private var managementLinks = PendingNetManagementLinkInbox()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(PendingNetLanguagePreferences.key) private var language = "system"

    var body: some Scene {
        WindowGroup {
            // 连接 / 设置两栏，对应 macOS 主窗口侧栏里的那两项。iOS 上底部
            // TabView 是系统惯例，不另开设置界面——和 macOS「设置就在主窗口
            // 里那一栏、不再弹独立小窗」是同一个决定。
            TabView(selection: $selectedTab) {
                PendingNetIOSHomeView()
                    .tabItem { Label("连接", systemImage: "bolt.horizontal.circle") }
                    .tag(0)
                PendingNetManagementView()
                    .tabItem { Label("管理", systemImage: "server.rack") }
                    .tag(1)
                PendingNetIOSSettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(2)
            }
            .environmentObject(controller)
            .environmentObject(toast)
                .environment(\.locale, language == "system" ? Locale.autoupdatingCurrent : Locale(identifier: language))
            .environmentObject(managementLinks)
            .tint(PendingNetTheme.Palette.accent)
            // 点一条 pendingnet:// 配对链接就直接导入。
            .onOpenURL { url in
                guard PendingNetPairingFile.isPairingScheme(url.scheme) else { return }
                if PendingNetPairingLinkDestination.isManagement(url) {
                    managementLinks.offer(url.absoluteString)
                    selectedTab = 1
                    return
                }
                Task { await controller.importAndEnroll(pasted: url.absoluteString) }
            }
            // Errors / success messages are now toasts, not inline banners that
            // linger. Observed at the root so both tabs surface them, and they
            // dismiss themselves; nil (cleared at the start of each op) is ignored.
            .onChange(of: controller.errorMessage) { _, value in
                if let value { toast.show(value) }
            }
            .onChange(of: controller.message) { _, value in
                if let value { toast.show(value, kind: .success) }
            }
            .overlay(alignment: .top) {
                PendingToastOverlay(center: toast)
            }
        }
        // 回到前台顺手拉一次 iCloud —— 在 Mac 上配好的 VPS 不用重开 App 就能
        // 出现在列表里。iCloud 用不了时这是空操作。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.refreshFromCloud() }
        }
    }

}
