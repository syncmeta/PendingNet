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

/// Makes helper start/stop requests idempotent before they touch launchd.
///
/// The UI can produce a second request while the first XPC round-trip is still
/// finishing. Rebuilding an already-live TUN makes the machine lose networking
/// again; booting out an already-stopped job turns a successful stop into a
/// launchctl error. Both repeated requests are successful no-ops instead.
public enum PendingNetEngineLifecycle {
    public enum StartAction: Equatable, Sendable {
        case reuseRunningEngine
        case launchEngine
    }

    public enum StopAction: Equatable, Sendable {
        case alreadyStopped
        case stopEngine(Int32)
    }

    public static func startAction(engineRunning: Bool) -> StartAction {
        engineRunning ? .reuseRunningEngine : .launchEngine
    }

    public static func stopAction(enginePID: Int32?) -> StopAction {
        enginePID.map(StopAction.stopEngine) ?? .alreadyStopped
    }

    public static func shouldRunSelfHeal(engineRunning: Bool) -> Bool {
        engineRunning
    }
}

/// 识别旧 App 留下的「仅端口」引擎时，能在无副作用层完成的部分。
///
/// 真正查监听者、核对控制密钥和发信号都在 macOS App 里；这里仅解析系统自带
/// `lsof -t` 的结果，避免一段诊断文字被误认成 PID 后伤到别的进程。
public enum PendingNetLocalEngineResidue {
    public static func parseListenerPIDs(_ output: String) -> [Int32] {
        var seen = Set<Int32>()
        var result: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty, line.allSatisfy(\.isNumber),
                  let pid = Int32(line), pid > 0, seen.insert(pid).inserted else { continue }
            result.append(pid)
        }
        return result
    }

    /// `lsof` 只回答谁占端口；还要把这条精确命令对上，才允许 App 收掉它。
    /// 不能只看进程名叫 sing-box，否则会伤到用户自己运行的另一份代理。
    public static func isOwnedCommand(
        _ command: String,
        binaryPath: String,
        configPath: String
    ) -> Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
            == "\(binaryPath) run -c \(configPath)"
    }
}
