import Foundation

/// 系统当前主链路的一张快照：谁是主网卡、它的地址、网关是谁。
///
/// 三样都取自 `State:/Network/Global/IPv4`（以及主服务的 IPv4 条目），因为
/// 出问题的正是这三样：换网卡之后 sing-box 的 `auto_detect_interface` 仍然
/// 拿旧网卡的 index / 源地址发包，代理腿和 direct 腿一起 `network is
/// unreachable`。
public struct PendingNetLinkSnapshot: Equatable, Sendable {
    /// 主网卡的 BSD 名，例如 `en0`、`en7`。拔了线又还没连上 Wi‑Fi 时为 nil。
    public var primaryInterface: String?
    /// 主网卡当前的 IPv4 地址。同一块网卡换了网段也算换了链路。
    public var primaryAddress: String?
    /// 默认网关。
    public var router: String?

    public init(
        primaryInterface: String? = nil,
        primaryAddress: String? = nil,
        router: String? = nil
    ) {
        self.primaryInterface = primaryInterface
        self.primaryAddress = primaryAddress
        self.router = router
    }

    /// 有主网卡才算「有网」。换网卡的中途会短暂落到这个状态，不能在这时候重启引擎
    /// —— 重启到一个没有默认路由的系统里，sing-box 一样起不来。
    public var isOnline: Bool {
        guard let primaryInterface else { return false }
        return !primaryInterface.isEmpty
    }

    /// 给日志用的人话，例如 `en7(192.168.1.17)`。
    public var describedForLog: String {
        guard let primaryInterface, !primaryInterface.isEmpty else { return "无主网卡" }
        guard let primaryAddress, !primaryAddress.isEmpty else { return primaryInterface }
        return "\(primaryInterface)(\(primaryAddress))"
    }
}

/// 「主链路变了要不要重启引擎」的全部判断，抽成一个纯粹的状态机。
///
/// 这是本机 TUN 断流的兜底自愈：sing-box 1.13 的 CLI 版在 macOS 上换网卡后
/// 不会重新绑定出站（`network_strategy` 那套只在图形客户端里有效，命令行版用
/// 不上），所以只能由 root 的 helper 看见变化后把引擎踢一下。
///
/// 判断本身不碰 SCDynamicStore、不碰 launchctl、不看时钟——时间是传进来的，
/// 所以整条去抖 / 节流 / 该不该重启的逻辑都能在单测里跑。
public struct PendingNetLinkWatchdog: Equatable {
    /// 换网卡之后等新网卡站稳的时间。macOS 上有线切无线要经过「都没有」的中间态，
    /// 这段时间里重启只会重启到一个还没成型的网络里。
    public static let defaultDebounce: TimeInterval = 3
    /// 两次自愈之间的最小间隔。网络抖动时不至于把引擎反复踢。
    public static let defaultThrottle: TimeInterval = 30

    public enum Decision: Equatable {
        /// 没事可做。
        case idle
        /// 有变化在手上，但还不能动——到这个时刻再来问一次。
        case wait(until: TimeInterval)
        /// 现在就重启引擎，`reason` 是要写进日志的那一行。
        case restart(reason: String)
    }

    public let debounce: TimeInterval
    public let throttle: TimeInterval

    /// 上一次看到的链路。第一次取值只当基线，不触发自愈。
    public private(set) var lastSnapshot: PendingNetLinkSnapshot?
    /// 已经上次自愈的时刻，用来节流。
    public private(set) var lastRestart: TimeInterval?

    private struct Pending: Equatable {
        /// 变化之前的链路，只在第一次发现变化时记下来，后面抖动不覆盖它——
        /// 日志里要说的是「从哪儿变到哪儿」，不是「从上一次抖动变到这次」。
        var from: PendingNetLinkSnapshot
        /// 最后一次看到变化的时刻，去抖从这里算起。
        var noticedAt: TimeInterval
    }
    private var pending: Pending?

    public init(
        debounce: TimeInterval = PendingNetLinkWatchdog.defaultDebounce,
        throttle: TimeInterval = PendingNetLinkWatchdog.defaultThrottle
    ) {
        self.debounce = debounce
        self.throttle = throttle
    }

    /// 唯一的入口：把「现在的链路」「引擎是不是本来就该在跑」「现在几点」交进来，
    /// 拿回该做什么。链路变化的回调和定时器复查都走这一个方法。
    ///
    /// - Parameters:
    ///   - snapshot: 刚读到的主链路。
    ///   - engineShouldRun: 引擎当前是不是处于「本来就该在跑」的状态。用户自己
    ///     停掉的引擎不该被自愈拉起来，所以这里为 false 时只更新基线。
    ///   - now: 单调递增的秒数。
    public mutating func evaluate(
        snapshot: PendingNetLinkSnapshot,
        engineShouldRun: Bool,
        at now: TimeInterval
    ) -> Decision {
        // 用户把引擎停了：链路怎么变都不关我们的事，但基线要跟上，
        // 免得他再启动时我们拿一份过期的基线立刻判成「变了」。
        guard engineShouldRun else {
            lastSnapshot = snapshot
            pending = nil
            return .idle
        }

        guard let previous = lastSnapshot else {
            // 第一次取值：只当基线。helper 刚起来不该踢引擎。
            lastSnapshot = snapshot
            return .idle
        }

        if snapshot != previous {
            lastSnapshot = snapshot
            // 每看到一次变化就把去抖窗口重新拉满：还在抖就接着等。
            pending = Pending(from: pending?.from ?? previous, noticedAt: now)
        }

        guard let pending else { return .idle }

        let ready = pending.noticedAt + debounce
        if now < ready { return .wait(until: ready) }

        // 中间态：线拔了、Wi-Fi 还没上来。重启到没有默认路由的系统里没有意义，
        // 继续等一个真正能用的链路。
        guard snapshot.isOnline else { return .wait(until: now + debounce) }

        if let lastRestart {
            let unblocked = lastRestart + throttle
            if now < unblocked { return .wait(until: unblocked) }
        }

        self.pending = nil
        lastRestart = now
        return .restart(
            reason: "主链路从 \(pending.from.describedForLog) 变成 \(snapshot.describedForLog)，"
                + "sing-box 的出站不会自己重新绑定，重启引擎"
        )
    }
}
