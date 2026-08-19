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
    public var isOnline: Bool { Self.normalized(primaryInterface) != nil }

    /// 两份快照是不是同一条链路。
    ///
    /// 只看网卡和地址：这两样才决定 sing-box 的出站绑在哪儿。默认网关**不算**——
    /// 同一块网卡、同一个地址，网关字符串抖一下（DHCP 续约、SCDynamicStore 先后
    /// 写入两个键）跟出站绑定没有关系，而重启引擎的代价是全机断网，误判比漏判贵得多。
    /// 本机 10:22:50 那次「从 en7(192.168.1.17) 变成 en7(192.168.1.17)」的自愈，
    /// 就是被这种变化触发的。
    ///
    /// nil 和空串当同一回事：SCDynamicStore 在切换中途会把键写成空，那不是一条新链路。
    public func isSameLink(as other: PendingNetLinkSnapshot) -> Bool {
        Self.normalized(primaryInterface) == Self.normalized(other.primaryInterface)
            && Self.normalized(primaryAddress) == Self.normalized(other.primaryAddress)
    }

    /// 给日志用的人话，例如 `en7(192.168.1.17) 网关 192.168.1.2`。
    ///
    /// 网关必须一起印出来，哪怕它不参与「要不要重启」的判断：日志是事后唯一的物证，
    /// 只印网卡和地址的话，一条网关引发的变化在日志里就长成「从 X 变成 X」，没人看得懂。
    public var describedForLog: String {
        let interface = Self.normalized(primaryInterface)
        let address = Self.normalized(primaryAddress)
        let link: String
        switch (interface, address) {
        case (nil, _): link = "无主网卡"
        case (let interface?, nil): link = "\(interface)(无地址)"
        case (let interface?, let address?): link = "\(interface)(\(address))"
        }
        return link + " 网关 " + (Self.normalized(router) ?? "无")
    }

    /// 空串一律当没有：SCDynamicStore 里「这个键暂时没值」既可能是缺键也可能是空串。
    static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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

        // 基线永远跟上最新一份快照，网关也记进去——它不触发重启，但下一次
        // 「从哪儿变到哪儿」要拿它来说话。
        lastSnapshot = snapshot

        if !snapshot.isSameLink(as: previous) {
            // 每看到一次真正的链路变化就把去抖窗口重新拉满：还在抖就接着等。
            // 只有网关变了的话这里不动，pending 也不会凭空冒出来。
            pending = Pending(from: pending?.from ?? previous, noticedAt: now)
        }

        guard let pending else { return .idle }

        // 抖回原地了：网卡和地址跟出发时一模一样（比如拔掉网线又插回同一个口，
        // 或者中途只有网关变过）。出站还绑在同一条链路上，重启只会白断一次网。
        if snapshot.isSameLink(as: pending.from) {
            self.pending = nil
            return .idle
        }

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
