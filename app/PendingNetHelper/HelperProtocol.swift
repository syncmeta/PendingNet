import Foundation

@objc public protocol HelperProtocol {
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
    /// Turns off a helper-owned system proxy that has no running engine behind
    /// it. Replies true when such a stale proxy was actually cleared.
    func repairSystemProxy(reply: @escaping (Bool) -> Void)
}
