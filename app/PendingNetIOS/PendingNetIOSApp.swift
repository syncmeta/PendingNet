import SBTallyCore
import SwiftUI

@main
struct PendingNetIOSApp: App {
    @StateObject private var controller = PendingNetIOSController()
    /// 短暂浮层提示。错误 / 成功消息不再常驻在卡片里，改成弹一下自动消失--
    /// 否则一条一次性的报错会一直挂在界面上，问题修好了也还在。
    @StateObject private var toast = PendingToastCenter()
    @Environment(\.scenePhase) private var scenePhase

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
            .environmentObject(toast)
            .tint(PendingNetTheme.Palette.accent)
            // 从「文件」、AirDrop 或别的 App 点开一个 .pdn，或者点一条
            // pendingnet:// 配对链接，都直接配对，不用先进 App 再点导入。
            // 两份声明都在 project.yml 的 info 段里；只声明不接住的话，
            // PendingNet 会出现在「打开方式」里、点了却什么都不发生，比不
            // 声明更糟。
            .onOpenURL { url in
                // 与 macOS 同一句守卫（见 PendingNetConnectionWorkflow 的
                // `importAndConnect(opened:)`）。认不出来的 URL 一律不理：
                // `importAndEnroll` 里是 `Data(contentsOf:)`——真收到一个 http
                // URL 就成了一次同步网络请求。两端对「什么算可导入」的判断
                // 不一致，正是这一轮在消灭的那类东西。
                if url.isFileURL {
                    guard url.pathExtension.lowercased() == "pdn" else { return }
                    Task { await importPairing(from: url) }
                    return
                }
                guard url.scheme?.lowercased() == PendingNetPairingFile.urlScheme else { return }
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

    /// 导入一个从外面点进来的 `.pdn`，并把系统替我们拷进来的那份删掉。
    ///
    /// 因为我们声明了不支持就地打开，系统会把文件**拷一份**放进
    /// `Documents/Inbox/` 再把这个 URL 交给我们。那份拷贝里装着 VPS 的配对
    /// 凭据，读完必须删——**成功失败都删**：失败时留着最没道理，用户以为
    /// 这次导入没发生，凭据却已经躺在设备上了。
    private func importPairing(from url: URL) async {
        defer { Self.removeInboxCopy(url) }
        await controller.importAndEnroll(url: url)
    }

    /// 只删系统拷进 Inbox 的那份，绝不碰用户自己的文件。
    ///
    /// 判据是「这个路径在本 App 容器的 Documents/Inbox 底下」。就地打开的原件
    /// （iCloud 云盘、别的 App 的容器）不在这个目录里，因此永远走不到删除。
    /// 宁可漏删也不能误删：漏删只是留下一份我们自己的拷贝，误删是把用户的
    /// 文件弄没了。
    private static func removeInboxCopy(_ url: URL) {
        guard url.isFileURL else { return }
        let inbox = URL.documentsDirectory
            .appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath()
        guard url.resolvingSymlinksInPath().path.hasPrefix(inbox.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
