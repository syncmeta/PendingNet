import Foundation
import Network

/// 「一台 VPS 一个延迟数」。两端共用这一份，语义必须完全一样：
/// **本机到这台 VPS 代理入口的一次 TCP 握手往返时间**。
///
/// 几条刻意的规矩：
/// - 不是 ICMP ping。ping 走的端口和用户的流量不是一回事，很多 VPS 还直接
///   把 ICMP 丢掉，测出来的「不通」是假的。
/// - 不按协议出数。Reality 和 Hysteria2 各测一次得到的两个数字，差别多半是
///   偶然波动，摆在用户面前只会让人以为要在两者之间做选择。
/// - 不混搭「当前这台走代理测、别的直连测」。同一列数字必须可比，混了就没法
///   横向比较，而横向比较正是这一列数字唯一的用处。
public struct PendingNetLatencyTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 代理入口：Reality 的 TCP 端口，用户的 TCP 流量真的落在这里。
        case proxyEntry
        /// 兜底：还没拉到节点资料时只知道控制端口。
        case controlPort
    }

    public let host: String
    public let port: Int
    public let kind: Kind

    public init(host: String, port: Int, kind: Kind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    /// 「详情」里那行说明——测的到底是哪个端点，一句话说清。
    public var explanation: String {
        switch kind {
        case .proxyEntry:
            "测的是代理入口 \(host):\(port)（TCP 握手，直连不经隧道）"
        case .controlPort:
            "测的是控制端口 \(host):\(port)（还没拉到节点资料，先测这里）"
        }
    }

    /// 这台 VPS 该测哪个端点。
    ///
    /// 优先代理入口：那是用户实际连接会走的通道，端口被封或服务没起来时这里
    /// 就是不通的，而控制端口照样会答应——只测控制端口等于报喜不报忧。
    /// 拉到节点资料之前退回控制端口，总比一个数字都没有强，但要在详情里讲明白。
    public static func forVPS(_ record: PairedVPSRecord) -> PendingNetLatencyTarget? {
        if let host = record.proxyTCPHost, !host.isEmpty,
           let port = record.proxyTCPPort, isValidPort(port) {
            return PendingNetLatencyTarget(host: host, port: port, kind: .proxyEntry)
        }
        guard let components = URLComponents(string: record.endpoint),
              let host = components.host, !host.isEmpty else { return nil }
        // 控制端点一直是带端口的；万一没有，按 https 的默认端口算。
        let port = components.port ?? 443
        guard isValidPort(port) else { return nil }
        return PendingNetLatencyTarget(host: host, port: port, kind: .controlPort)
    }

    private static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }
}

public extension PairedVPSRecord {
    /// 把节点资料里的代理入口记到这条记录上，下次测延迟就有的测了。
    ///
    /// 只认 Reality：Hysteria2 是 UDP/QUIC，没有 TCP 握手可以计时，硬凑一个
    /// QUIC 握手时间和这一列的语义又对不上。VPS 上只剩 Hysteria2 时把这两项
    /// 清掉——留着上一次的端口只会让延迟测一个已经不存在的服务。
    mutating func adoptProxyEntry(from profile: PendingNetNodeProfile) {
        let reality = profile.protocols.compactMap(\.vlessReality).first {
            !$0.server.isEmpty && (1...65535).contains($0.serverPort)
        }
        proxyTCPHost = reality?.server
        proxyTCPPort = reality?.serverPort
    }
}

/// 一台 VPS 的延迟结果。界面上的文案也在这里，两端一字不差。
public enum PendingNetLatencyOutcome: Equatable, Sendable {
    case measuring
    case ok(milliseconds: Int, target: PendingNetLatencyTarget)
    case failed(String)

    /// VPS 列表那一行右边显示的东西。测量中返回 nil——那时候该显示转圈。
    /// 只给数字，不带「延迟」二字：那一列是什么，列表下面已经写清楚了。
    public var rowText: String? {
        switch self {
        case .measuring: nil
        case .ok(let milliseconds, _): "\(milliseconds) ms"
        case .failed: "不通"
        }
    }

    /// 失败原因，说人话。行下面和详情里都用它。
    public var failureText: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    /// 详情里的完整说法：数字 + 测的是哪个端点。
    public var detailText: String? {
        switch self {
        case .measuring: "正在测…"
        case .ok(let milliseconds, let target): "\(milliseconds) ms · \(target.explanation)"
        case .failed(let reason): reason
        }
    }
}

public enum PendingNetLatencyError: Error, Equatable {
    /// 记录里的地址读不出来，连测点都定不了。
    case unresolvableAddress
    /// 超过等待上限还没握上手。
    case timedOut
}

/// 把底层错误翻译成人话。用户要知道的是「被拒了 / 超时了 / 域名解析不了」，
/// 不是 POSIX 错误号。
public enum PendingNetLatencyFailure {
    public static func message(for error: Error, target: PendingNetLatencyTarget) -> String {
        if let latencyError = error as? PendingNetLatencyError {
            switch latencyError {
            case .unresolvableAddress:
                return "这台 VPS 的地址读不出来，重新导入它的 .pdn 就好"
            case .timedOut:
                return "连接超时：\(target.port) 端口一直没有回应，可能被防火墙拦住了"
            }
        }
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED:
                    return "连接被拒绝：这台 VPS 的 \(target.port) 端口上没有服务在听"
                case .ETIMEDOUT:
                    return "连接超时：\(target.port) 端口一直没有回应，可能被防火墙拦住了"
                case .EHOSTUNREACH, .ENETUNREACH:
                    return "网络到不了这台 VPS，先看看本机网络"
                case .ECONNRESET:
                    return "连接被对方掐断了，这台 VPS 上的服务可能不正常"
                default:
                    break
                }
            case .dns:
                return "域名解析不了：检查一下这台 VPS 的地址和本机 DNS"
            default:
                break
            }
        }
        return "连不上这台 VPS：\(error.localizedDescription)"
    }
}

/// 逐台 VPS 测延迟，结果按 serverID 存着给界面用。两端共用同一个实现。
@MainActor
public final class PendingNetLatencyTester: ObservableObject {
    /// 单测用的注入点：返回握手毫秒数，或者抛错。
    public typealias Probe = @Sendable (_ host: String, _ port: Int, _ timeout: TimeInterval) async throws -> Int

    @Published public private(set) var results: [String: PendingNetLatencyOutcome] = [:]

    private let timeout: TimeInterval
    private let probe: Probe

    public init(
        timeout: TimeInterval = 5,
        probe: @escaping Probe = PendingNetTCPProbe.handshake
    ) {
        self.timeout = timeout
        self.probe = probe
    }

    public func outcome(for serverID: String) -> PendingNetLatencyOutcome? { results[serverID] }

    public func isMeasuring(_ serverID: String) -> Bool { results[serverID] == .measuring }

    public var busy: Bool { results.values.contains(.measuring) }

    public func measure(_ record: PairedVPSRecord) async {
        guard let target = PendingNetLatencyTarget.forVPS(record) else {
            results[record.serverID] = .failed(
                PendingNetLatencyFailure.message(
                    for: PendingNetLatencyError.unresolvableAddress,
                    target: PendingNetLatencyTarget(host: "", port: 0, kind: .controlPort)
                )
            )
            return
        }
        results[record.serverID] = .measuring
        do {
            let milliseconds = try await probe(target.host, target.port, timeout)
            results[record.serverID] = .ok(milliseconds: milliseconds, target: target)
        } catch {
            results[record.serverID] = .failed(
                PendingNetLatencyFailure.message(for: error, target: target)
            )
        }
    }

    /// 逐台测一遍。并发跑：一台不通要等到超时，串行会让后面的一起陪等。
    public func measureAll(_ records: [PairedVPSRecord]) async {
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { @MainActor in await self.measure(record) }
            }
        }
    }

}

/// 真正的 TCP 握手计时。放在类外面：它不碰任何主线程状态，也不该被主线程隔离。
public enum PendingNetTCPProbe {
    /// 一次 TCP 连接建立所花的时间，毫秒。
    ///
    /// `prohibitedInterfaceTypes = [.other]` 是要紧的一笔：隧道 / VPN 接口正是
    /// `.other`，不挡住的话隧道一开，这个探测自己就会被路进隧道，测出来的是
    /// 「经代理再绕回 VPS」的往返，和隧道没开时的数字根本不可比。NWConnection
    /// 本身不认系统 HTTP 代理，所以那一头不用另外挡。
    public static let handshake: PendingNetLatencyTester.Probe = { host, port, timeout in
        guard let rawPort = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw PendingNetLatencyError.unresolvableAddress
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
        let queue = DispatchQueue(label: "com.pendingname.pendingnet.latency.\(UUID().uuidString)")
        let started = DispatchTime.now()

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            @Sendable func settle(_ result: Result<Int, Error>) {
                guard gate.close() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    settle(.success(Int(elapsed)))
                case .failed(let error):
                    settle(.failure(error))
                case .waiting(let error):
                    // `.waiting` 表示这条路现在走不通（被拒、没有路由）。当成
                    // 失败报出来，不然界面会一直转圈到超时为止。
                    settle(.failure(error))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                settle(.failure(PendingNetLatencyError.timedOut))
            }
            connection.start(queue: queue)
        }
    }

    /// continuation 只能 resume 一次；超时和状态回调可能同时到。
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false

        /// 第一次调用返回 true，之后都返回 false。
        func close() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }
    }
}
