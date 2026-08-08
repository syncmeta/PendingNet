import Foundation

/// App 与 Packet Tunnel Extension 共用的 App Group 目录布局。
///
/// 两侧必须引用同一份定义：扩展读的就是 App 写的那几个文件，
/// 各写各的路径常量会在真机上表现为「配置明明写了但扩展读不到」。
public enum PendingNetTunnelPaths {
    public static let appGroupID = "group.com.pendingname.pendingnet"

    public static func container(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func configURL(in base: URL) -> URL {
        base.appendingPathComponent("config.json")
    }

    /// startTunnel options 的持久化快照。系统按 on-demand 规则在 App
    /// 未运行时拉起隧道时，options 为空，扩展回退读这里。
    public static func snapshotURL(in base: URL) -> URL {
        base.appendingPathComponent("start-options.json")
    }

    /// The removed `direct` route mode produced a snapshot that bypasses every
    /// proxy. Once the stored preference migrates to `global`, keeping that
    /// snapshot would let Settings start a direct tunnel while the app displays
    /// 全局. Delete it so the extension fails visibly until the app supplies a
    /// fresh configuration.
    public static func invalidateSnapshotForRemovedDirectMode(
        storedRouteModeRawValue rawValue: String,
        in base: URL?,
        fileManager: FileManager = .default
    ) {
        guard rawValue == "direct", let base else { return }
        let snapshot = snapshotURL(in: base)
        guard fileManager.fileExists(atPath: snapshot.path) else { return }
        try? fileManager.removeItem(at: snapshot)
    }

    public static func cacheURL(in base: URL) -> URL {
        base.appendingPathComponent("cache.db")
    }

    /// 扩展进程自身 stderr（fd 2）的落点，由扩展在 `startTunnel` 里用
    /// `freopen` 自行重定向。
    ///
    /// **这里没有 sing-box 的内核日志。** libbox 一旦拿到 platform interface
    /// 就把 `defaultLogWriter` 设成 `io.Discard`，日志改走 `PlatformLogWriter`
    /// 进 command server 的环形缓冲，从不经过 stderr；`LibboxRedirectStderr`
    /// 也不重定向 fd 2（它只接管 Go 崩溃栈，见 `crashLogURL`）。内核日志的
    /// 唯一出口是 command client 订阅 `LibboxCommandLog`。
    ///
    /// 这个文件里只有扩展自己 `writeMessage` 写的诊断行（以及扩展进程里
    /// 其他任何往 stderr 写的东西）。放在 App Group 里，主 App 才读得到。
    public static func stderrLogURL(in base: URL) -> URL {
        base.appendingPathComponent("stderr.log")
    }

    /// Go 运行时崩溃栈的落点（`LibboxRedirectStderr` → `debug.SetCrashOutput`）。
    ///
    /// 必须与 `stderrLogURL` 分开：`RedirectStderr` 内部是 `os.Create`，
    /// 指向同一个文件会把已经在追加写的诊断日志截断掉。
    public static func crashLogURL(in base: URL) -> URL {
        base.appendingPathComponent("go-crash.log")
    }

    /// 扩展 `startTunnel` 失败时留下的错误原文。
    ///
    /// `NEVPNConnection` 不向 App 传递扩展抛出的错误——App 只看得到 status
    /// 翻到 `.disconnected`。没有这个文件，「隧道起不来」在 App 里没有任何
    /// 可诊断的信息。启动成功时由扩展删除。
    public static func lastErrorURL(in base: URL) -> URL {
        base.appendingPathComponent("last-error.txt")
    }

    public static func ruleSetDirectory(in base: URL) -> URL {
        base.appendingPathComponent("rulesets", isDirectory: true)
    }

    public static func prepare(
        base: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: ruleSetDirectory(in: base),
            withIntermediateDirectories: true
        )
    }
}
