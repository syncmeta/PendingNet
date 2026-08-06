import SwiftUI

@main
struct PendingNetIOSApp: App {
    @StateObject private var controller = PendingNetIOSController()

    var body: some Scene {
        WindowGroup {
            PendingNetIOSHomeView()
                .environmentObject(controller)
        }
    }
}
