import Foundation

/// SBTallyCore is also used by the app's management UI. Its user-facing
/// errors must resolve against the app's localization, not the Swift package.
func pendingNetAdminLocalized(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "PendingNet management error")
}
