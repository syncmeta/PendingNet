import Combine
import Foundation
import Sparkle

@MainActor
final class PendingNetUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let updaterController: SPUStandardUpdaterController
    let isConfigured: Bool

    private var cancellable: AnyCancellable?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = URL(string: feed)?.scheme == "https" && !publicKey.isEmpty
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
        if isConfigured { updaterController.startUpdater() }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updaterController.checkForUpdates(nil)
    }

    /// 自动检查 / 自动下载：这两项 Sparkle 自己会存进 SUEnableAutomaticChecks 与
    /// SUAutomaticallyUpdate，所以直接读写它，不另存一份。
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
            // 不检查就无从下载 —— 别留下一个开着却永远不动的开关。
            if !newValue { updaterController.updater.automaticallyDownloadsUpdates = false }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }
}
