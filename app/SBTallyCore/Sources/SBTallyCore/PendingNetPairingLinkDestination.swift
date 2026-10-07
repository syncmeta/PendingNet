import Foundation

/// Classify a deep link before starting either enrollment workflow. Decoding
/// validates the document but never consumes its one-time grant.
public enum PendingNetPairingLinkDestination {
    public static func isManagement(_ url: URL, now: Date = Date()) -> Bool {
        guard url.scheme?.lowercased() == PendingNetPairingFile.urlScheme,
              let pairing = try? PendingNetPairingFile.decode(link: url.absoluteString, now: now) else {
            return false
        }
        return pairing.enrollment.role == "admin"
    }
}
