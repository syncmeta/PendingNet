import Foundation

/// 重启引擎这件事里不需要跑进程就能定下来的部分：等多久、怎么从 launchd 的
/// 输出里认出引擎的 pid。
///
/// 为什么要有这些：原来所有重启都走 `launchctl kickstart -k`，`-k` 是 SIGKILL。
/// sing-box 被硬杀之后来不及拆掉自己的 TUN、把系统的 DNS 和路由还原，launchd
/// 又立刻把新实例拉起来——新实例读到的主链路可能还是空的，于是
/// `/var/log/sbtally-singbox.log` 里就出现 `missing default interface`：进程活着，
/// 但没网。所以要先 SIGTERM 请它自己退、确认那个进程真的没了，再拉新的。
public enum PendingNetEngineRestart {
    /// SIGTERM 之后等引擎自己退的时间。sing-box 拆 TUN + 还原网络状态一般在 1 秒内。
    public static let gracefulStopTimeout: TimeInterval = 5
    /// 超时后补一刀 SIGKILL，再等这么久。
    public static let forcedStopTimeout: TimeInterval = 2
    /// 查一次「退了没」的间隔。
    public static let pollInterval: TimeInterval = 0.1

    /// 从 `launchctl print system/io.sbtally.singbox` 的输出里挖出引擎的 pid。
    ///
    /// 取第一条形如 `pid = 123` 的行：job 自己的 pid 排在所有子字典（endpoints 之类）
    /// 前面。没有这行说明 job 当前没有进程在跑（bootout 过、或者 KeepAlive 还没拉起来）。
    public static func parsePID(launchctlPrintOutput: String) -> Int32? {
        for line in launchctlPrintOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            let value = trimmed.dropFirst("pid = ".count)
            guard !value.isEmpty, value.allSatisfy(\.isNumber) else { continue }
            return Int32(value)
        }
        return nil
    }
}
