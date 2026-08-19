import Foundation

/// 重启之后引擎到底有没有绑上网卡，以及绑不上时还要不要再来一次。
///
/// launchd 说「running」只代表进程还在，不代表这个引擎能用。sing-box 起来的那一刻
/// 如果系统还没有默认路由，`auto_detect_interface` 就绑不到网卡，日志里连着吐：
///
///     ERROR network: missing default interface
///     ERROR dns/local[dns-local]: fetch DNS servers: dhcp: prepare interface: missing default interface
///
/// 进程活得好好的，整机没网——本机 8/19 那次就是这个状态。这里定的是「怎么从
/// 新写进日志的那一段里认出这种废掉的启动，以及还能再试几次」；读文件、睡觉、
/// 真去重启都在 helper 那薄薄一层壳里。
public enum PendingNetEngineHealth {
    /// 绑不到网卡时 sing-box 吐的那句。
    public static let unboundInterfaceMarker = "missing default interface"
    /// 重启后等日志落地的时间。这几行是启动时写的，1 秒内就出来了。
    public static let defaultSettleDelay: TimeInterval = 1.5
    /// 判定为废掉之后，隔多久再重启一次——给系统一点时间把默认路由装回来。
    public static let defaultRetryDelay: TimeInterval = 2
    /// 最多补重启几次。再多就是拿全机的网反复赌，不如把状态写进日志留给人看。
    public static let defaultMaxRetries = 2

    public enum Verdict: Equatable {
        /// 这次起来是好的。
        case healthy
        /// 废了，隔 `after` 秒再重启一次，这是第 `attempt` 次补救。
        case retry(attempt: Int, after: TimeInterval)
        /// 补救过 `afterRestarts` 次还是废的，别再踢了。
        case giveUp(afterRestarts: Int)
    }

    /// 这一段日志是不是「起来了但没绑上网卡」。
    ///
    /// 只看新写进去的那一段：这个日志是 launchd 一路追加的，历史上那 4 条
    /// 早就在文件里躺着，拿整份文件判会永远判成废的。
    public static func isUnbound(freshLog: String) -> Bool {
        freshLog.contains(unboundInterfaceMarker)
    }

    public static func verdict(
        freshLog: String,
        retriesSoFar: Int,
        maxRetries: Int = PendingNetEngineHealth.defaultMaxRetries,
        retryDelay: TimeInterval = PendingNetEngineHealth.defaultRetryDelay
    ) -> Verdict {
        guard isUnbound(freshLog: freshLog) else { return .healthy }
        guard retriesSoFar < maxRetries else { return .giveUp(afterRestarts: retriesSoFar + 1) }
        return .retry(attempt: retriesSoFar + 1, after: retryDelay)
    }

    /// 重启后该从文件的哪个字节开始读。
    ///
    /// 正常就是重启前的大小；但引擎日志有轮转（原地截断），中间被截过的话
    /// 旧的大小就成了文件尾巴外面的位置，那时候从头读。
    public static func tailOffset(previousSize: Int, currentSize: Int) -> Int {
        guard previousSize > 0, previousSize <= currentSize else { return 0 }
        return previousSize
    }
}
