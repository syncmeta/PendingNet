import Foundation

/// 引擎日志该不该截断、截断后保留多少尾巴。
///
/// launchd 的 `StandardOutPath` 只会一路追加，没有任何轮转——本机那份
/// `/var/log/sbtally-singbox.log` 就这么长到了 160MB。newsyslog 在这里也不合用：
/// 它把文件改名之后 sing-box 手上的 fd 还指着旧 inode，除非能给进程发信号让它
/// 重开，而这个 daemon 没有 pidfile。
///
/// 所以走「原地截断」：launchd 是以 `O_APPEND` 打开这个文件的，把它 truncate 到 0
/// 之后，进程的下一次写入自然落回文件开头，不会留下空洞。截断前先把尾巴抄一份到
/// `.1`，留一代历史。
public enum PendingNetLogRotation {
    /// 超过这个大小就截断。
    public static let defaultSizeLimit = 20 * 1024 * 1024
    /// 截断前保留到 `.1` 的尾巴大小。
    public static let defaultKeepTail = 2 * 1024 * 1024

    public enum Plan: Equatable {
        /// 还没到线，别动。
        case keep
        /// 截断，并且把末尾这么多字节先抄到 `.1`。
        case rotate(keepingLastBytes: Int)
    }

    public static func plan(
        size: Int,
        limit: Int = PendingNetLogRotation.defaultSizeLimit,
        keepTail: Int = PendingNetLogRotation.defaultKeepTail
    ) -> Plan {
        guard size > limit else { return .keep }
        return .rotate(keepingLastBytes: max(0, min(keepTail, size)))
    }

    /// `.1` 的路径。
    public static func archivePath(for path: String) -> String { path + ".1" }
}
