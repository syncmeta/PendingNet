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
public let pendingNetHelperInterfaceVersion = 6

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

    // MARK: - Interface version 3

    /// When this helper process started, as seconds since 1970.
    ///
    /// The interface version alone only catches *protocol* changes, so a
    /// release that fixes helper behaviour without touching `HelperProtocol`
    /// would leave the old daemon resident and its bugs live — which is the
    /// exact shape of the bug this whole handshake exists to prevent. Comparing
    /// this against the mtime of the helper binary in the app bundle catches
    /// that too: a helper that started before the binary on disk was written is
    /// not running that binary.
    func startedAt(reply: @escaping (Double) -> Void)

    // MARK: - Interface version 4

    /// Switches the helper-run engine's routing to `mode` — one of
    /// `Global` / `Whitelist` / `Blacklist`. Replies nil on success, otherwise
    /// text for the user.
    ///
    /// TUN and 系统代理 run a second sing-box, started by this daemon as root,
    /// whose Clash API secret the app never sees — so 全局/白名单/黑名单 could
    /// only ever be switched in 「仅端口」. Worse, that config defaults to
    /// `Whitelist`, so the GUI could highlight 全局 while the engine routed by
    /// the whitelist. This is the app's way to reach that engine.
    ///
    /// The mode is also recorded on disk and replayed after every engine start:
    /// `store_mode` is off, so a restart (switching takeover, applying a VPS)
    /// otherwise drops back to the config's default and quietly loses the pick.
    func setRouteMode(_ mode: String, reply: @escaping (String?) -> Void)

    // MARK: - Interface version 5

    /// 这个 daemon 管着的那份统计采集器：在不在跑、统计接口在哪个端口、起不来的话
    /// 为什么。
    ///
    /// 和 `setRouteMode` 是同一个道理：TUN / 系统代理那份 sing-box 由这个 daemon
    /// 用 root 起，它的 Clash API 密钥不交给 app，所以采集器也只能由这一侧起。
    /// app 那边照旧只从统计端口读数据 —— 它不需要知道自己处在哪种接管方式，只需要
    /// 知道现在有没有人在采、没有的话该跟用户说什么。
    func statsStatus(reply: @escaping (Bool, Int, String?) -> Void)

    // MARK: - Interface version 6

    /// TUN / 系统代理那份 root 引擎当前选中的 VPS selector。控制口密钥不能交给
    /// App，所以 App 不能像「仅端口」那样直接读 `/proxies`；由 helper 返回它
    /// 已成功应用并在每次启动时重放的 selector tag，供服务器列表画勾。
    func activeSelectorTag(reply: @escaping (String?) -> Void)
}

/// 这一对身份从前是散在 app、助手、launchd plist、签名脚本里的字面量。
/// 2026-08-08 把 macOS 从 `net.pending.*` 归一到 `com.pendingname.*`（和 iOS 同一个
/// App ID）时，靠人肉逐处找才不至于漏。Swift 这一侧从此只认这里这一份。
///
/// 仍然要手工对齐的只剩两处（都没法引用 Swift 常量）：
/// `PendingNetHelper/com.pendingname.pendingnet.helper.plist` 与
/// `scripts/sign-macos-development.sh`。
public enum PendingNetIdentifiers {
    public static let app = "com.pendingname.pendingnet"
    public static let helper = app + ".helper"
    public static let helperPlistName = helper + ".plist"

    /// 0.3.18 及以前 macOS 版的身份。只用来收拾残留 —— 旧的 launchd job、旧的
    /// `UserDefaults` 域。任何新代码都不该拿它去注册、签名或连接什么。
    public static let legacyApp = "net.pending.PendingNet"
    public static let legacyHelper = legacyApp + ".helper"
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
