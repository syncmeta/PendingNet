import Darwin
import Foundation

/// 本机混合入站（HTTP + SOCKS 共用一个端口）的设置：端口，以及要不要让
/// 同一个局域网里的其它设备也能用。
///
/// 两端共用一份。macOS 的「仅端口」模式里这个入站**就是**产品本身；iOS 的
/// 隧道里它和 tun 并存——手机上真正在接管流量的是 tun，这个入站是给同网段
/// 的电脑、电视之类当代理用的。语义、取值范围、错误说法两端逐字相同。
public struct PendingNetLocalInbound: Equatable, Sendable {
    public static let defaultPort = 2080
    public static let portRange = 1024...65535
    /// 只给本机。
    public static let loopbackListen = "127.0.0.1"
    /// 给整个局域网。
    public static let anyListen = "0.0.0.0"
    /// 配置里这个入站的 tag，两端同名。
    public static let tag = "pendingnet-local"

    public var port: Int
    /// 开着就监听 0.0.0.0，同网段的设备也能通过这台机器上网。
    public var allowsLAN: Bool

    public init(port: Int = PendingNetLocalInbound.defaultPort, allowsLAN: Bool = false) {
        self.port = port
        self.allowsLAN = allowsLAN
    }

    public var listenAddress: String {
        allowsLAN ? Self.anyListen : Self.loopbackListen
    }

    public static func isValidListenAddress(_ address: String) -> Bool {
        address == loopbackListen || address == anyListen
    }

    /// 生成配置里的那段 inbound。
    public var configuration: [String: Any] {
        [
            "type": "mixed",
            "tag": Self.tag,
            "listen": listenAddress,
            "listen_port": port,
        ]
    }

    /// 把用户输入的那一串变成端口号，不合格就当场说清是哪一种不合格。
    ///
    /// - Parameters:
    ///   - text: 输入框里的原文。
    ///   - current: 现在用的端口。和它相同就跳过占用探测——正在跑的引擎
    ///     自己占着那个端口，探它只会把用户自己报成「被别的程序占用」。
    ///   - listenAddress: 要监听在哪。探占用就探这个地址——允许局域网访问时
    ///     我们真正要占的是 0.0.0.0，只探 127.0.0.1 会漏掉冲突。
    ///   - reservedPort: 本端另有别用、不能被抢走的端口（macOS 是 sing-box
    ///     的控制端口 29090）。iOS 的隧道没有这种端口，传 nil。
    ///   - isFree: 占用探测。测试里换掉，别真去 bind。
    public static func resolvePort(
        from text: String,
        current: Int,
        listenAddress: String = PendingNetLocalInbound.loopbackListen,
        reservedPort: Int? = nil,
        isFree: (Int, String) -> Bool = PendingNetLocalInbound.portIsFree
    ) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), String(port) == trimmed else {
            throw PendingNetLocalInboundError.notANumber
        }
        guard portRange.contains(port) else { throw PendingNetLocalInboundError.outOfRange }
        if let reservedPort, port == reservedPort {
            throw PendingNetLocalInboundError.reserved(reservedPort)
        }
        if port != current, !isFree(port, listenAddress) {
            throw PendingNetLocalInboundError.inUse(port)
        }
        return port
    }

    /// 此刻有没有别人占着这个地址上的这个端口。
    ///
    /// 探的是 bind 而不是 connect：端口可能被一个拒绝连接的进程占着，那种
    /// connect 探不出来，但我们照样起不来。
    ///
    /// 带 `SO_REUSEADDR` 是为了和内核真正要做的事一致（Go 的监听器默认就带
    /// 它）：不带的话，上一轮跑在这个端口上、还处在 TIME_WAIT 的连接会让
    /// bind 失败，我们就会把用户自己刚用过的端口报成「被别的程序占用」。
    public static func portIsFree(
        _ port: Int,
        listenAddress: String = PendingNetLocalInbound.loopbackListen
    ) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr.s_addr = inet_addr(listenAddress)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

/// 端口改不成时给用户看的话。四种情形分开说——「保存失败」这种话等于
/// 什么都没说，用户不知道该改成什么。
public enum PendingNetLocalInboundError: LocalizedError, Equatable {
    case notANumber
    case outOfRange
    case reserved(Int)
    case inUse(Int)

    public var errorDescription: String? {
        switch self {
        case .notANumber:
            "端口只能是数字，比如 2080。"
        case .outOfRange:
            // verbatim 区间：1024 / 65535 是标识符不是数量
            "端口要在 1024 到 65535 之间。"
        case .reserved(let port):
            "\(port) 是 PendingNet 自己的控制端口，换一个。"
        case .inUse(let port):
            "端口 \(port) 已经被别的程序占用了，换一个再试。"
        }
    }
}

/// 端口 / 局域网设置的存档。两端同一套键名。
public struct PendingNetLocalInboundStore: Sendable {
    public static let portKey = "pendingnet.local-proxy-port"
    public static let lanKey = "pendingnet.allow-lan"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 存档里的端口不在合法区间（没存过、手改过、早年版本写坏了）就退回
    /// 出厂值：拿一个非法端口去生成配置，结果是内核直接拒收整份配置。
    public func load() -> PendingNetLocalInbound {
        let stored = defaults.integer(forKey: Self.portKey)
        return PendingNetLocalInbound(
            port: PendingNetLocalInbound.portRange.contains(stored)
                ? stored
                : PendingNetLocalInbound.defaultPort,
            allowsLAN: defaults.bool(forKey: Self.lanKey)
        )
    }

    public func save(_ inbound: PendingNetLocalInbound) {
        defaults.set(inbound.port, forKey: Self.portKey)
        defaults.set(inbound.allowsLAN, forKey: Self.lanKey)
    }
}
