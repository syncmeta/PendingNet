import Foundation
import Network

/// One comparable value per VPS: TCP handshake to its proxy entry, or ICMP
/// echo to its host. ICMP does not validate the proxy service. Management ports
/// are never used as a substitute for a missing TCP proxy.
public struct PendingNetLatencyTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 代理入口：Reality 的 TCP 端口，用户的 TCP 流量真的落在这里。
        case proxyEntry
        /// 兜底：还没拉到节点资料时只知道控制端口。
        case controlPort
        /// 通过选中出站真实访问 HTTPS 测试站。
        case proxyAccess
        case icmpEcho
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
            String(format: localizedLatency("代理入口 %@:%lld"), host, Int64(port))
        case .controlPort:
            String(format: localizedLatency("控制端口 %@:%lld"), host, Int64(port))
        case .proxyAccess:
            String(format: localizedLatency("经所选代理访问 %@"), host)
        case .icmpEcho:
            "ICMP \(host)"
        }
    }

    /// 这台 VPS 该测哪个端点。
    ///
    /// 优先代理入口：那是用户实际连接会走的通道，端口被封或服务没起来时这里
    /// 就是不通的，而控制端口照样会答应——只测控制端口等于报喜不报忧。
    /// 没有 TCP 代理入口时不测管理口；UDP-only 节点可使用 ICMP。
    public static func forVPS(_ record: PairedVPSRecord) -> PendingNetLatencyTarget? {
        if let host = record.proxyTCPHost, !host.isEmpty,
           let port = record.proxyTCPPort, isValidPort(port) {
            return PendingNetLatencyTarget(host: host, port: port, kind: .proxyEntry)
        }
        return nil
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
        let hy = profile.protocols.compactMap(\.hysteria2).first
        proxyUDPHost = hy?.server
        proxyUDPPort = hy?.serverPort
    }
}

/// 一台 VPS 的延迟结果。界面上的文案也在这里，两端一字不差。
public enum PendingNetLatencyOutcome: Equatable, Sendable {
    case measuring
    case ok(milliseconds: Int, target: PendingNetLatencyTarget)
    case failed(String)

    /// VPS 列表那一行右边显示的东西。测量中返回 nil——那时候该显示转圈。
    /// 数字旁标明「代理」或「端口」，避免把实际出站访问与 TCP 握手混淆。
    public var rowText: String? {
        switch self {
        case .measuring: nil
        case .ok(let milliseconds, let target):
            "\(milliseconds) ms · \((target.kind == .proxyAccess ? localizedLatency("代理") : target.kind == .icmpEcho ? "ICMP" : "TCP"))"
        case .failed: localizedLatency("不通")
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
        case .measuring: localizedLatency("正在测…")
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
    /// 出站代理没有完成 HTTPS 测试。
    case proxyTestFailed
}

/// 把底层错误翻译成人话。用户要知道的是「被拒了 / 超时了 / 域名解析不了」，
/// 不是 POSIX 错误号。
public enum PendingNetLatencyFailure {
    public static func message(for error: Error, target: PendingNetLatencyTarget) -> String {
        if let latencyError = error as? PendingNetLatencyError {
            switch latencyError {
            case .unresolvableAddress:
                return localizedLatency("这台 VPS 的地址读不出来，请重新导入它的链接")
            case .timedOut:
                return String(format: localizedLatency("连接超时：%lld 端口一直没有回应，可能被防火墙拦住了"), Int64(target.port))
            case .proxyTestFailed:
                return localizedLatency("代理访问测试未通过，请检查连接和协议")
            }
        }
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED:
                    return String(format: localizedLatency("连接被拒绝：这台 VPS 的 %lld 端口上没有服务在听"), Int64(target.port))
                case .ETIMEDOUT:
                    return String(format: localizedLatency("连接超时：%lld 端口一直没有回应，可能被防火墙拦住了"), Int64(target.port))
                case .EHOSTUNREACH, .ENETUNREACH:
                    return localizedLatency("网络到不了这台 VPS，先看看本机网络")
                case .ECONNRESET:
                    return localizedLatency("连接被对方掐断了，这台 VPS 上的服务可能不正常")
                default:
                    break
                }
            case .dns:
                return localizedLatency("域名解析不了：检查一下这台 VPS 的地址和本机 DNS")
            default:
                break
            }
        }
        return String(format: localizedLatency("连不上这台 VPS：%@"), error.localizedDescription)
    }
}

private func localizedLatency(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "VPS latency feedback")
}

/// 逐台 VPS 测延迟，结果按 serverID 存着给界面用。两端共用同一个实现。
@MainActor
public final class PendingNetLatencyTester: ObservableObject {
    /// 单测用的注入点：返回握手毫秒数，或者抛错。
    public typealias Probe = @Sendable (_ host: String, _ port: Int, _ timeout: TimeInterval) async throws -> Int

    @Published public private(set) var results: [String: PendingNetLatencyOutcome] = [:]

    private let timeout: TimeInterval
    private let probe: Probe
    private let icmpProbe: Probe

    public init(
        timeout: TimeInterval = 5,
        probe: @escaping Probe = PendingNetTCPProbe.handshake,
        icmpProbe: @escaping Probe = PendingNetICMPProbe.echo
    ) {
        self.timeout = timeout
        self.probe = probe
        self.icmpProbe = icmpProbe
    }

    public func outcome(for serverID: String) -> PendingNetLatencyOutcome? { results[serverID] }

    public func isMeasuring(_ serverID: String) -> Bool { results[serverID] == .measuring }

    public var busy: Bool { results.values.contains(.measuring) }

    public func measure(_ record: PairedVPSRecord, method: PendingNetLatencyMethod = .tcp) async {
        let selectedTarget: PendingNetLatencyTarget?
        if method == .icmp {
            let host = record.proxyTCPHost ?? record.proxyUDPHost ?? record.address
            selectedTarget = host.isEmpty ? nil : .init(host: host, port: 0, kind: .icmpEcho)
        } else {
            selectedTarget = PendingNetLatencyTarget.forVPS(record)
        }
        guard let target = selectedTarget else {
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
            let milliseconds = try await (method == .icmp ? icmpProbe : probe)(target.host, target.port, timeout)
            results[record.serverID] = .ok(milliseconds: milliseconds, target: target)
        } catch {
            results[record.serverID] = .failed(
                PendingNetLatencyFailure.message(for: error, target: target)
            )
        }
    }

    /// 当前已连接的 VPS：强制经其出站访问 HTTPS 测试站，不碰其他节点的选择。
    public func measureProxy(
        _ record: PairedVPSRecord,
        probe: @escaping @Sendable () async throws -> Int
    ) async {
        let target = PendingNetLatencyTarget(
            host: "www.gstatic.com", port: 443, kind: .proxyAccess
        )
        results[record.serverID] = .measuring
        do {
            results[record.serverID] = .ok(milliseconds: try await probe(), target: target)
        } catch {
            results[record.serverID] = .failed(
                PendingNetLatencyFailure.message(for: error, target: target)
            )
        }
    }

    /// 逐台测一遍。并发跑：一台不通要等到超时，串行会让后面的一起陪等。
    public func measureAll(
        _ records: [PairedVPSRecord],
        method: PendingNetLatencyMethod = .tcp,
        activeServerID: String? = nil,
        proxyProbe: (@Sendable () async throws -> Int)? = nil
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { @MainActor in
                    if record.serverID == activeServerID, let proxyProbe {
                        await self.measureProxy(record, probe: proxyProbe)
                    } else {
                        await self.measure(record, method: method)
                    }
                }
            }
        }
    }

}

/// 真正的 TCP 握手计时。放在类外面：它不碰任何主线程状态，也不该被主线程隔离。
public enum PendingNetTCPProbe {
    /// 一次 TCP 连接建立所花的时间，毫秒。
    ///
    /// 这里必须服从系统当前路由。不能用 `prohibitedInterfaceTypes = [.other]`
    /// 排除 TUN：VPN 已接管默认路由时 Network.framework 不会因此自动改走物理
    /// 网卡，只会直接报 `ENETDOWN`，于是连接状态下所有 VPS 都显示「不通」。
    /// sing-box 已把自己的服务器端点排除在代理回环之外；系统代理模式下
    /// NWConnection 也不会套用 HTTP 代理，因此直接按当前路由握手即可。
    public static let handshake: PendingNetLatencyTester.Probe = { host, port, timeout in
        guard let rawPort = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw PendingNetLatencyError.unresolvableAddress
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())

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
