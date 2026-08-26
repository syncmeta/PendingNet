import Darwin
import XCTest
@testable import SBTallyCore

/// 本机入站（端口 + 允许局域网）的判断两端共用一份，这里钉住它。
///
/// 这些判断以前只长在 macOS 的 PendingNetUserEngine 里、而且一半在视图里做
/// （「端口只能是数字」那条），iOS 侧根本没有。做成一份之后，两端说出来的话
/// 必须逐字相同——不然同一个错在手机上和电脑上是两种说法。
final class PendingNetLocalInboundTests: XCTestCase {
    func testListenAddressFollowsTheLANSwitch() {
        XCTAssertEqual(PendingNetLocalInbound(port: 2080, allowsLAN: false).listenAddress, "127.0.0.1")
        XCTAssertEqual(PendingNetLocalInbound(port: 2080, allowsLAN: true).listenAddress, "0.0.0.0")
    }

    func testNonNumericPortIsRejectedInPlainWords() {
        XCTAssertThrowsError(
            try PendingNetLocalInbound.resolvePort(from: "两千零八十", current: 2080)
        ) { error in
            XCTAssertEqual(error as? PendingNetLocalInboundError, .notANumber)
            XCTAssertEqual(error.localizedDescription, "端口只能是数字，比如 2080。")
        }
        XCTAssertThrowsError(try PendingNetLocalInbound.resolvePort(from: "", current: 2080))
        XCTAssertThrowsError(try PendingNetLocalInbound.resolvePort(from: "20 80", current: 2080))
    }

    func testPortIsTrimmedBeforeParsing() throws {
        // 这里只测字符串修剪，不把本机此刻谁占了 2081 混进来（开发机上可能正有
        // 用户自己的代理在用它）。端口占用另有专门用例。
        XCTAssertEqual(try PendingNetLocalInbound.resolvePort(
            from: "  2081 ", current: 2080, isFree: { _, _ in true }
        ), 2081)
    }

    func testPortOutOfRangeIsCalledOutSeparatelyFromGarbage() {
        for text in ["80", "1023", "65536", "0", "-1"] {
            XCTAssertThrowsError(
                try PendingNetLocalInbound.resolvePort(from: text, current: 2080),
                "\(text) 应当被判为超范围"
            ) { error in
                XCTAssertEqual(error as? PendingNetLocalInboundError, .outOfRange)
                XCTAssertEqual(error.localizedDescription, "端口要在 1024 到 65535 之间。")
            }
        }
    }

    func testControlPortIsReservedOnlyWhereOneExists() {
        XCTAssertThrowsError(
            try PendingNetLocalInbound.resolvePort(from: "29090", current: 2080, reservedPort: 29090)
        ) { error in
            XCTAssertEqual(error as? PendingNetLocalInboundError, .reserved(29090))
            XCTAssertEqual(error.localizedDescription, "29090 是 PendingNet 自己的控制端口，换一个。")
        }
        // iOS 的隧道里没有 clash_api，控制通道走 App Group 里的 unix socket，
        // 没有任何端口该被保留 —— 那边传 nil，29090 就是个普通端口。
        XCTAssertEqual(
            try? PendingNetLocalInbound.resolvePort(
                from: "29090", current: 2080, reservedPort: nil, isFree: { _, _ in true }
            ),
            29090
        )
    }

    func testOccupiedPortIsNamed() {
        XCTAssertThrowsError(
            try PendingNetLocalInbound.resolvePort(
                from: "2081", current: 2080, isFree: { _, _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? PendingNetLocalInboundError, .inUse(2081))
            XCTAssertEqual(error.localizedDescription, "端口 2081 已经被别的程序占用了，换一个再试。")
        }
    }

    /// 探占用要探这次真正要监听的那个地址。开着「允许局域网访问」时要占的是
    /// 0.0.0.0，只探 127.0.0.1 会把一个真冲突放过去，然后隧道 / 引擎在起的时候
    /// 才炸——那时用户已经离开设置页了。
    func testOccupancyProbeUsesTheAddressWeWillActuallyListenOn() throws {
        var probedAddress: String?
        _ = try PendingNetLocalInbound.resolvePort(
            from: "2081",
            current: 2080,
            listenAddress: PendingNetLocalInbound.anyListen,
            isFree: { _, address in probedAddress = address; return true }
        )
        XCTAssertEqual(probedAddress, "0.0.0.0")
    }

    /// 占用检查只对「换一个端口」有意义。保持原端口不动（比如只是拨一下
    /// 「允许局域网访问」）时不能去探它：正在跑的引擎自己就占着那个端口，
    /// 一探就会把用户自己的引擎报成「被别的程序占用」。
    func testKeepingTheCurrentPortSkipsTheOccupancyProbe() throws {
        var probed = false
        let port = try PendingNetLocalInbound.resolvePort(
            from: "2080",
            current: 2080,
            isFree: { _, _ in probed = true; return false }
        )
        XCTAssertEqual(port, 2080)
        XCTAssertFalse(probed, "端口没变就不该去探占用")
    }

    /// 探测是真的 bind 一下，不是去 connect：端口可能被一个拒绝连接的进程
    /// 占着，connect 探不出来，bind 探得出来。
    func testOccupancyProbeSeesARealListener() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(listener < 0, "无法创建套接字")
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // 让内核挑一个空闲端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "bind 失败：\(String(cString: strerror(errno)))")
        var bindings = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bindings) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        let port = Int(UInt16(bigEndian: bindings.sin_port))
        try XCTSkipIf(port < 1024, "内核挑的端口落在保留段")
        XCTAssertEqual(listen(listener, 1), 0)

        XCTAssertFalse(PendingNetLocalInbound.portIsFree(port), "有人在听的端口不该算空闲")
    }

    func testStoreRoundTripsThroughDefaults() throws {
        let suite = "pendingnet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingNetLocalInboundStore(defaults: defaults)

        // 没存过就是出厂设置：2080、只给本机。
        XCTAssertEqual(store.load(), PendingNetLocalInbound(port: 2080, allowsLAN: false))

        store.save(PendingNetLocalInbound(port: 2081, allowsLAN: true))
        XCTAssertEqual(store.load(), PendingNetLocalInbound(port: 2081, allowsLAN: true))

        // 键名是老的那两个：改名等于把老用户的端口设置悄悄打回 2080。
        XCTAssertEqual(defaults.integer(forKey: "pendingnet.local-proxy-port"), 2081)
        XCTAssertTrue(defaults.bool(forKey: "pendingnet.allow-lan"))

        // 存档里的荒唐值（手改过、或早年版本写坏的）退回出厂端口，而不是
        // 拿它去生成一份内核必然拒收的配置。
        defaults.set(80, forKey: "pendingnet.local-proxy-port")
        XCTAssertEqual(store.load().port, 2080)
    }
}
