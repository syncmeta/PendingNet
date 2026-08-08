import Foundation
import Security

/// Bumped whenever `HelperProtocol` gains, drops, or changes a method.
///
/// The app compiles in this value and asks the *running* helper for its own.
/// The two disagree exactly when launchd is still running a helper binary left
/// over from a previous install — the helper is a resident daemon, so replacing
/// the app bundle does not replace it, and nothing else ever restarts it.
///
/// That mismatch is not cosmetic: `NSXPCConnection` tears the whole connection
/// down when it decodes a selector the remote interface doesn't declare, so a
/// single call to a newly added method against a stale helper turns every
/// subsequent call into 「Couldn't communicate with a helper application」.
/// Version 2 added `repairSystemProxy`, which is precisely how that was
/// discovered. Anything past version 1 must therefore stay behind the
/// handshake in `EngineController`.
public let pendingNetHelperInterfaceVersion = 2

@objc public protocol HelperProtocol {
    // MARK: - Interface version 1
    // Present in every helper ever shipped, so these stay safe to send without
    // knowing which build is on the other end.

    func startEngine(reply: @escaping (String?) -> Void)          // nil = ok, else error text
    func stopEngine(reply: @escaping (String?) -> Void)
    func setTakeover(_ mode: String, reply: @escaping (String?) -> Void) // "tun"|"sysproxy"|"local"
    func applyServerConfiguration(
        _ serverID: String,
        name: String,
        selectorTag: String,
        proxyOutbounds: Data,
        reply: @escaping (String?) -> Void
    )
    func status(reply: @escaping (Bool, String, String) -> Void)  // running, mode, lastLogTail

    // MARK: - Interface version 2
    // Never send these until `interfaceVersion` has confirmed the helper is
    // current — against an older helper they drop the connection instead.

    /// Turns off a helper-owned system proxy that has no running engine behind
    /// it. Replies true when such a stale proxy was actually cleared.
    func repairSystemProxy(reply: @escaping (Bool) -> Void)
    /// The `pendingNetHelperInterfaceVersion` the *running* helper was built
    /// with. A helper too old to implement this drops the message and kills the
    /// connection, which the app reads as "stale helper" just the same.
    func interfaceVersion(reply: @escaping (Int) -> Void)
    /// Asks the helper to exit so launchd relaunches the current bundle's
    /// binary on the next connection. One-way by design: the process is gone
    /// before any reply could be delivered.
    func quitForUpgrade()
}

/// Code-signing requirement one side of the XPC pair demands of the other,
/// matched to how *this* binary is itself signed.
///
/// A Developer ID build insists the peer carries the same Team ID; a locally
/// signed development build has no team at all, so it can only insist on the
/// signing identifier. Hard-coding the production team would leave every local
/// build unable to talk to the helper it was built alongside.
public func pendingNetCodeRequirement(identifier: String) -> String {
    let base = "identifier \"\(identifier)\""
    guard let team = pendingNetSelfTeamIdentifier() else { return base }
    return base + " and anchor apple generic"
        + " and certificate leaf[subject.OU] = \"\(team)\""
}

/// Team ID this binary is signed with, or nil when it carries no team —
/// ad-hoc/locally signed builds, which is the expected development case.
private func pendingNetSelfTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
    ) == errSecSuccess else { return nil }
    return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}

/// Whether the process behind `pid` satisfies `requirement`.
///
/// Identifying the peer by pid rather than audit token is a deliberate
/// trade-off: `NSXPCConnection.auditToken` is not public API. The residual
/// pid-reuse race needs an attacker to land a pid between XPC accepting the
/// connection and this check, which is a far smaller hole than the one this
/// closes — before it, any process on the machine could drive a root daemon.
public func pendingNetProcessSatisfies(pid: pid_t, requirement text: String) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}
