import Foundation

/// 统计服务（`sbtally daemon`）的落地判断。
///
/// 这一层里没有进程、没有 launchctl、没有网络 —— 全是「给定观察到的事实，
/// 应该怎么做」。真正去跑的那一层在 macOS App 里（`PendingNetStatsDaemon`），
/// 它只负责观察和执行，判断都从这里取，所以判断本身能被单测钉死。
public enum PendingNetStatsService {
    /// 统计接口的默认端口。App 读的就是它，`sbtally daemon` 默认也监听它。
    public static let defaultPort = 7777

    /// 默认端口被别的程序占住时依次再试的几个。范围留窄：统计接口是本机自用的，
    /// 换到离得远的端口对用户毫无意义，不如早点说清「被谁占了」。
    public static let portCandidates: [Int] = Array(defaultPort...(defaultPort + 9))

    // MARK: - 密钥

    /// 从引擎那份 `control-secret` 里读出密钥。
    ///
    /// 读不到 / 是空的都返回 nil —— 这两种都不是「密钥是空串」，而是「现在还没有
    /// 密钥」，调用方该等引擎先把它写出来，而不是拿着空串去认证然后被 401。
    public static func readSecret(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 端口

    /// 一个候选端口上现在是什么。
    public enum PortState: Equatable, Sendable {
        /// 没人监听。
        case free
        /// 上面就是一份 sbtally 统计接口 —— 多半是老残留的那个采集器。
        case sbtally
        /// 有人监听，但不是我们的东西。
        case foreign
    }

    /// 该拿哪个端口，以及拿之前要不要先收拾谁。
    public enum PortOutcome: Equatable, Sendable {
        /// 端口空着，直接用。
        case use(Int)
        /// 默认端口上蹲着另一份 sbtally —— 先把老的收掉再用这个端口。
        /// 不换端口是有意的：两个采集器会写同一个 SQLite 库，换端口只是让冲突
        /// 从「抢端口」变成「抢数据库」，更难查。
        case takeOverLegacy(Int)
        /// 候选端口全被别的程序占了。带上候选清单，好把话说清楚。
        case allOccupied([Int])
    }

    public static func choosePort(
        candidates: [Int] = portCandidates,
        probe: (Int) -> PortState
    ) -> PortOutcome {
        guard let first = candidates.first else { return .allOccupied([]) }
        switch probe(first) {
        case .free: return .use(first)
        case .sbtally: return .takeOverLegacy(first)
        case .foreign: break
        }
        // 默认端口被别的程序占了才走到这里。后面的候选只认「空着」：另一份
        // sbtally 蹲在非默认端口上不是我们放的，也就不是我们该去收的。
        for port in candidates.dropFirst() where probe(port) == .free {
            return .use(port)
        }
        return .allOccupied(candidates)
    }

    // MARK: - 老残留

    /// 老的用户级 LaunchAgent（`deploy/install.sh` 那条手工安装路径留下的）。
    ///
    /// 它指着旧的 Clash 端口和旧密钥，而且开机自启 —— 不收拾掉，它会和 App 自己
    /// 管的那份抢同一个 7777 和同一个 SQLite 库。
    public enum LegacyAgent {
        public static let label = "io.sbtally.daemon"

        /// 该对它做什么。
        public enum Action: Equatable, Sendable {
            /// 没有这份残留，什么都不用做。
            case nothingToDo
            /// 已加载，但 plist 不在原处（有人手工 bootstrap 过）：卸掉就完了，
            /// 没有文件要挪，下次登录也不会自己回来。
            case bootOut
            /// plist 还在：卸掉 + 挪走。只 bootout 的话，下次登录 launchd 又把它
            /// 拉起来，冲突每次开机重演一遍。
            case bootOutAndArchive(plist: URL, archive: URL)
        }

        /// 默认的 plist 位置：`~/Library/LaunchAgents/io.sbtally.daemon.plist`。
        public static func plistURL(home: URL) -> URL {
            home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        }

        /// 挪走之后放哪。留在同一个目录、只改后缀，是为了让人一眼看见它还在、
        /// 也能一条 `mv` 就还原 —— 直接删掉就没有回头路了。
        /// 后缀不是 `.plist`，launchd 不会再收它。
        public static func archiveURL(for plist: URL) -> URL {
            plist.deletingPathExtension().appendingPathExtension("plist.pendingnet-disabled")
        }

        public static func plan(plistExists: Bool, isLoaded: Bool, home: URL) -> Action {
            let plist = plistURL(home: home)
            if plistExists {
                return .bootOutAndArchive(plist: plist, archive: archiveURL(for: plist))
            }
            return isLoaded ? .bootOut : .nothingToDo
        }
    }

    // MARK: - 谁来跑采集器

    /// 这台机器上现在该由谁跑采集器。
    ///
    /// 接管方式决定引擎是谁起的，也就决定采集器只能由谁起：「仅端口」那份引擎是
    /// App 自己的子进程，控制密钥就在用户目录里；TUN / 系统代理那份是特权助手用
    /// root 起的，密钥按设计不出助手（见 `PendingNetHelper/main.swift` 的
    /// `clashRequest`），只能请助手代劳 —— 和路由模式走 `setRouteMode` 是同一条路。
    ///
    /// 这个函数存在的意义是「同一时刻只有一个 owner」：两边各起一个就会抢同一个
    /// 统计端口和同一个 SQLite 库。
    public enum CollectorOwner: Equatable, Sendable {
        case app
        case helper
        /// 没有引擎在跑，也就没有东西可采。
        case nobody
    }

    public static func collectorOwner(takeover: String, engineRunning: Bool) -> CollectorOwner {
        guard engineRunning else { return .nobody }
        return takeover == "local" ? .app : .helper
    }

    /// 采集器的命令行。
    ///
    /// 密钥**不在里面** —— `ps` 是全机可见的。App 那侧用 `-secret-file` 指向引擎
    /// 自己那份文件，助手那侧用 `-secret-stdin` 走管子。
    ///
    /// - Parameter databasePath: 三种接管方式都写同一个库，切来切去统计不清零。
    ///   助手那份采集器因此必须降到登录用户身份去跑，不然这个库和它的 -wal/-shm
    ///   会变成 root 所有，「仅端口」模式下的采集器就再也写不进去了。
    public static func daemonArguments(
        clashAPI: String,
        port: Int,
        databasePath: String,
        secret: SecretDelivery
    ) -> [String] {
        var arguments = [
            "daemon",
            "-clash-api", clashAPI,
            "-listen", "127.0.0.1:\(port)",
            "-db", databasePath,
            // 规则集另有人管（App 侧是自己的下载器，助手侧那份目录 root 才写得进
            // 去），采集器别去碰。
            "-ruleset-dir", "",
        ]
        switch secret {
        case .file(let path):
            arguments += ["-secret-file", path]
        case .standardInput:
            arguments.append("-secret-stdin")
        }
        return arguments
    }

    public enum SecretDelivery: Equatable, Sendable {
        case file(String)
        case standardInput
    }

    /// 登录用户的统计库。三种接管方式共用它。
    public static func databasePath(home: String) -> String {
        home + "/Library/Application Support/sbtally/sbtally.db"
    }

    // MARK: - 界面上该说什么

    /// 统计服务这一侧现在是什么状态。
    public enum DaemonState: Equatable, Sendable {
        case stopped
        case running(port: Int)
        /// 起不来，带着给用户看的原因。
        case failed(String)
    }

    /// 统计页面该显示哪一种空状态。「读不到」有好几种成因，从前全被糊成一句
    /// 「统计服务尚未启用」—— 那句话既不说为什么，也不说下一步。
    public enum Availability: Equatable, Sendable {
        /// 有数据，正常显示。
        case ready
        /// 引擎没在跑：先连上再说，跟统计服务没关系。
        case engineStopped
        /// 引擎在跑、统计服务也在跑，就是这段时间没有流量。
        case noTraffic
        /// 统计服务起不来，带原因。
        case unavailable(reason: String)
    }

    /// - Parameter readFailed: 上一次读统计接口失败了。统计服务明明在跑却读不到，
    ///   跟「在跑但这段时间没流量」是两件完全不同的事，不能都显示成没有数据。
    public static func availability(
        engineRunning: Bool,
        daemon: DaemonState,
        hasData: Bool,
        readFailed: Bool = false
    ) -> Availability {
        if hasData { return .ready }
        if case .failed(let reason) = daemon { return .unavailable(reason: reason) }
        guard engineRunning else { return .engineStopped }
        if case .running(let port) = daemon {
            if readFailed {
                return .unavailable(
                    reason: "统计服务在跑（端口 \(port)），但这一次没读到数据。稍等一下，或者重新连接一次。")
            }
            return .noTraffic
        }
        // 引擎在跑但统计服务停着 —— 正常路径上不该出现（两者同生命周期），
        // 真出现了也别装作没有数据。
        return .unavailable(reason: "统计服务没有随代理一起启动。")
    }

    /// 空状态上那两行字。三个统计页共用一份，省得措辞各说各的。
    public struct EmptyMessage: Equatable, Sendable {
        public let title: String
        public let detail: String
        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// - Parameter subject: 这个页面在说什么，例如「应用流量」「域名」。
    public static func emptyMessage(
        for availability: Availability,
        subject: String
    ) -> EmptyMessage {
        switch availability {
        case .ready:
            return EmptyMessage(title: "暂时没有\(subject)", detail: "有新数据时会自动显示在这里。")
        case .engineStopped:
            return EmptyMessage(
                title: "还没有连接",
                detail: "统计只记录经过 PendingNet 的流量。先在「连接」里连上 VPS，这里就会有\(subject)。"
            )
        case .noTraffic:
            return EmptyMessage(
                title: "这段时间没有流量",
                detail: "已连接，但选定时间内没有经过 PendingNet 的\(subject)。换一个时间范围看看。"
            )
        case .unavailable(let reason):
            return EmptyMessage(title: "统计服务没能启动", detail: reason)
        }
    }
}
