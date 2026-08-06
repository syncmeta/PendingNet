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
}
