import Foundation

/// App 与 Packet Tunnel Extension 共用的 App Group 目录布局。
///
/// 两侧必须引用同一份定义：扩展读的就是 App 写的那几个文件，
/// 各写各的路径常量会在真机上表现为「配置明明写了但扩展读不到」。
public enum PendingNetTunnelPaths {
    public static let appGroupID = "group.net.pending.PendingNet"

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

    public static func cacheURL(in base: URL) -> URL {
        base.appendingPathComponent("cache.db")
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
