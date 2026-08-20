import Foundation

/// 引擎启停之后要冲一次 macOS 的系统 DNS 缓存：什么时候冲、冲哪两条命令、
/// 哪条失败算失败。
///
/// 为什么必须做这件事：本机 2026-08-20 抓到的现场——`dscacheutil -q host -a name
/// www.google.com` 回的是 31.13.92.37（Facebook 的段，GFW 投毒的典型应答），
/// 同一时刻 `dig` 走引擎回的是 fake-ip 198.18.0.8，`curl --resolve` 指到 fake-ip
/// 上 200 只要 1.1 秒。也就是说隧道一直是好的，坏的只有系统缓存里那一条脏记录。
///
/// 那条脏记录是开机后代理还没起来的那几秒进去的：系统去问运营商 DNS，被投了毒，
/// 之后 mDNSResponder 不再复查，只有重启机器才清——用户报的「平时就是重启电脑网
/// 才回来」「重启 sbtally 也没用」「clash 也救不回来」全是这一条解释的：毒在它们
/// 上游，重启引擎压根碰不到系统缓存。
///
/// 顺序是这里的要害：**必须在引擎起来之后冲**。引擎起来之前冲，冲掉的是旧记录，
/// 而这时候查出来的新记录仍然走没有代理的上游，等于白冲一次；停引擎那次同理，
/// 要在 TUN 拆掉之后，否则残留的 fake-ip 会把直连也一起废掉。`afterEngineUp` /
/// `afterEngineDown` 就是把这个顺序钉死，不让调用点写反。
///
/// 这里不跑进程、不写日志：真去 `Process` 和 `helperLog` 都在 helper 那薄薄一层壳里。
public enum PendingNetDNSCacheFlush {
    /// 冲刷发生在引擎的哪一侧。
    public enum Moment: Equatable, Sendable {
        /// 引擎起来之后。
        case afterEngineUp
        /// 引擎停掉、TUN 拆掉之后。
        case afterEngineDown
    }

    /// 谁要求的这次冲刷。日志里印的就是它，出事时一眼看得出是哪条路径。
    public enum Trigger: CaseIterable, Equatable, Sendable {
        /// 启动引擎。
        case engineStarted
        /// 切换接管模式（tun / sysproxy / local）导致的重启。
        case takeoverSwitched
        /// 应用 VPS 配置导致的重启。
        case serverConfigurationApplied
        /// 换网卡自愈导致的重启。
        case linkSelfHealed
        /// 停止引擎、拆掉 TUN。
        case engineStopped

        /// 写进 helper 日志的那个称呼。
        public var logLabel: String {
            switch self {
            case .engineStarted: return "启动引擎"
            case .takeoverSwitched: return "切换接管模式"
            case .serverConfigurationApplied: return "应用 VPS 配置"
            case .linkSelfHealed: return "换网卡自愈"
            case .engineStopped: return "停止引擎"
            }
        }

        public var moment: Moment {
            switch self {
            case .engineStopped: return .afterEngineDown
            case .engineStarted, .takeoverSwitched, .serverConfigurationApplied, .linkSelfHealed:
                return .afterEngineUp
            }
        }
    }

    /// 一条要跑的命令。两条都得是 root 才能做，helper 正好是 root。
    public struct Command: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// 主力：失败要在日志里说清楚。辅助失败不算失败。
        public let isRequired: Bool

        public init(executable: String, arguments: [String], isRequired: Bool) {
            self.executable = executable
            self.arguments = arguments
            self.isRequired = isRequired
        }

        public var describedForLog: String {
            ([executable] + arguments).joined(separator: " ")
        }
    }

    /// 辅助的一条：清 Directory Service 那层缓存。它在新系统上基本是空转，
    /// 失败（比如被系统改掉了子命令）也不影响真正管用的那一条。
    public static let flushDirectoryService = Command(
        executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"], isRequired: false)
    /// 主力的一条：SIGHUP 让 mDNSResponder 把自己缓存的应答全丢掉重新解析。
    /// 真正把那条脏记录清掉的就是它，所以它失败必须留痕。
    public static let flushMDNSResponder = Command(
        executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"], isRequired: true)

    /// 跑的顺序：先清 DS 那层，再让 mDNSResponder 重来——反过来的话，
    /// 前脚刚重来的解析器可能又被后脚清掉的那层喂回一条旧记录。
    public static let commands: [Command] = [flushDirectoryService, flushMDNSResponder]

    /// 一条命令跑完的结果。0 是成功，跟 shell 一个约定。
    public struct CommandResult: Equatable, Sendable {
        public let command: Command
        public let exitCode: Int32

        public init(command: Command, exitCode: Int32) {
            self.command = command
            self.exitCode = exitCode
        }

        public var succeeded: Bool { exitCode == 0 }
    }

    public enum Outcome: Equatable, Sendable {
        /// 两条都成了。
        case flushed
        /// 主力成了，辅助的挂了——缓存已经冲掉，只是日志里记一笔。
        case degraded(failed: [String])
        /// 主力挂了，这次冲刷等于没冲。仍然只记日志，不让引擎启停整体失败。
        case failed(failed: [String])
    }

    /// 把几条命令的退出码归成一个结论。
    ///
    /// 主力挂了就是 `.failed`，哪怕辅助的成功了——真正清掉脏记录的是主力。
    public static func outcome(results: [CommandResult]) -> Outcome {
        let failures = results.filter { !$0.succeeded }
        guard !failures.isEmpty else { return .flushed }
        let names = failures.map(\.command.describedForLog)
        if failures.contains(where: \.command.isRequired) {
            return .failed(failed: names)
        }
        return .degraded(failed: names)
    }

    /// 每次冲刷留的那一行日志，写清是哪个时刻触发的。
    public static func logLine(trigger: Trigger, outcome: Outcome) -> String {
        let head = "\(trigger.logLabel)：冲刷系统 DNS 缓存"
        switch outcome {
        case .flushed:
            return head + "，已冲掉"
        case .degraded(let failed):
            return head + "，已冲掉（\(failed.joined(separator: "、")) 失败，不影响）"
        case .failed(let failed):
            return head + "失败（\(failed.joined(separator: "、"))）——"
                + "系统缓存里被投毒的记录可能还在，外网可能仍然打不开"
        }
    }

    /// 先把引擎弄起来，起来了才冲缓存。
    ///
    /// 引擎没起来就不冲：那时候查出来的还是没走代理的上游，冲了也只会立刻被
    /// 重新投毒一遍。`bringUp` 返回 nil 表示引擎在跑；返回错误时原样传出去，
    /// 一次都不冲。
    @discardableResult
    public static func afterEngineUp(
        _ trigger: Trigger,
        bringUp: () -> String?,
        flush: (Trigger) -> Void
    ) -> String? {
        if let error = bringUp() { return error }
        flush(trigger)
        return nil
    }

    /// 先把引擎停掉、TUN 拆掉，再冲缓存。
    ///
    /// 停这一侧同样重要：TUN 在的时候解析出来的是 fake-ip（198.18.x.x），引擎一走
    /// 那些地址就没人接了，缓存里留着它们连直连都废掉。
    ///
    /// 跟起来那一侧不一样的是：`stop` 报错也照冲——引擎可能已经半死不活、TUN 已经
    /// 拆了一半，这时候缓存里的 fake-ip 更需要清掉。错误照原样传出去。
    @discardableResult
    public static func afterEngineDown(
        _ trigger: Trigger,
        stop: () -> String?,
        flush: (Trigger) -> Void
    ) -> String? {
        let error = stop()
        flush(trigger)
        return error
    }
}
