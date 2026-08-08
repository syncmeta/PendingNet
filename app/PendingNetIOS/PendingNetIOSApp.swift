import SwiftUI

@main
struct PendingNetIOSApp: App {
    @StateObject private var controller = PendingNetIOSController()

    var body: some Scene {
        WindowGroup {
            // 连接 / 设置两栏，对应 macOS 主窗口侧栏里的那两项。iOS 上底部
            // TabView 是系统惯例，不另开设置界面——和 macOS「设置就在主窗口
            // 里那一栏、不再弹独立小窗」是同一个决定。
            TabView {
                PendingNetIOSHomeView()
                    .tabItem { Label("连接", systemImage: "bolt.horizontal.circle") }
                PendingNetIOSSettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .environmentObject(controller)
            .tint(PendingNetTheme.Palette.accent)
        }
    }
}
