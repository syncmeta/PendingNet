import Foundation
import Libbox
import Network
import NetworkExtension
import os
import UserNotifications

/// libbox 内核与 NetworkExtension 之间的平台适配层。
///
/// 方法集合以 `app/Vendor/Libbox.xcframework` 里的 `Libbox.objc.h`
/// （sing-box v1.13.13）为准，**不是** SFI 主线那一份 —— 主线的
/// `LibboxPlatformInterface` 多出 SSH／neighbor／tailscale／writeLog
/// 等一批方法，本版本没有。另外 ObjC 侧的 `usePlatformAutoDetectInterfaceControl`
/// ／`autoDetectInterfaceControl:` ／`sendNotification:` 经 Swift 导入器
/// 改名为 `usePlatformAutoDetectControl` ／`autoDetectControl` ／`send`，
/// 按 Swift 名实现。改动前先读头文件，再让编译器裁决。
final class PendingNetPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol,
    LibboxCommandServerHandlerProtocol
{
    private static let logger = Logger(
        subsystem: "net.pending.PendingNet.ios.PacketTunnel",
        category: "PlatformInterface"
    )

    // 强引用，与参考实现一致。Go 侧的 command server 会一直持有本对象，
    // 若这里用 unowned，provider 先析构就是一次硬崩溃；反过来这个引用环
    // 至多让 provider 活到进程结束 —— 而它本来就活到进程结束。
    private let tunnel: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    // MARK: - tun

    /// `openTun` 是同步协议方法，而 `setTunnelNetworkSettings` 是异步的。
    ///
    /// 用 `runBlocking` 桥接：它在 detached Task 上跑，主调线程等信号量。
    /// 直接在当前 Task 上 `Task { }` + 信号量会有在 NE 的协作线程池里
    /// 自锁的风险 —— 这个 runBlocking 是参考实现里真机验证过的写法。
    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    private func openTun0(
        _ options: LibboxTunOptionsProtocol?,
        _ ret0_: UnsafeMutablePointer<Int32>?
    ) async throws {
        guard let options else {
            throw PendingNetTunnelError.message("tun options 为空")
        }
        guard let ret0_ else {
            throw PendingNetTunnelError.message("tun 返回指针为空")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            // v1.13 的 GetDNSServerAddress 返回单个 StringBox（不是迭代器，
            // 也没有 GetDNSMode）；未配置 auto_route DNS 时它返回 error。
            var dnsSettings: NEDNSSettings?
            if let dnsServer = try? options.getDNSServerAddress(), !dnsServer.value.isEmpty {
                let newDNSSettings = NEDNSSettings(servers: [dnsServer.value])
                settings.dnsSettings = newDNSSettings
                dnsSettings = newDNSSettings
            }

            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            if let ipv4AddressIterator = options.getInet4Address() {
                while ipv4AddressIterator.hasNext() {
                    guard let ipv4Prefix = ipv4AddressIterator.next() else { break }
                    ipv4Address.append(ipv4Prefix.address())
                    ipv4Mask.append(ipv4Prefix.mask())
                }
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)

            var ipv4Routes: [NEIPv4Route] = []
            if let routeIterator = options.getInet4RouteAddress() {
                while routeIterator.hasNext() {
                    guard let prefix = routeIterator.next() else { break }
                    ipv4Routes.append(
                        NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask())
                    )
                }
            }
            // 本工程生成的配置不带 route_address，走这条默认全量路由。
            if ipv4Routes.isEmpty {
                ipv4Routes.append(NEIPv4Route.default())
            }

            var ipv4ExcludeRoutes: [NEIPv4Route] = []
            if let excludeIterator = options.getInet4RouteExcludeAddress() {
                while excludeIterator.hasNext() {
                    guard let prefix = excludeIterator.next() else { break }
                    ipv4ExcludeRoutes.append(
                        NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask())
                    )
                }
            }

            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let ipv6AddressIterator = options.getInet6Address() {
                while ipv6AddressIterator.hasNext() {
                    guard let ipv6Prefix = ipv6AddressIterator.next() else { break }
                    ipv6Address.append(ipv6Prefix.address())
                    ipv6Prefixes.append(NSNumber(value: ipv6Prefix.prefix()))
                }
            }
            if !ipv6Address.isEmpty {
                let ipv6Settings = NEIPv6Settings(
                    addresses: ipv6Address,
                    networkPrefixLengths: ipv6Prefixes
                )

                var ipv6Routes: [NEIPv6Route] = []
                if let routeIterator = options.getInet6RouteAddress() {
                    while routeIterator.hasNext() {
                        guard let prefix = routeIterator.next() else { break }
                        ipv6Routes.append(
                            NEIPv6Route(
                                destinationAddress: prefix.address(),
                                networkPrefixLength: NSNumber(value: prefix.prefix())
                            )
                        )
                    }
                }
                if ipv6Routes.isEmpty {
                    ipv6Routes.append(NEIPv6Route.default())
                }

                var ipv6ExcludeRoutes: [NEIPv6Route] = []
                if let excludeIterator = options.getInet6RouteExcludeAddress() {
                    while excludeIterator.hasNext() {
                        guard let prefix = excludeIterator.next() else { break }
                        ipv6ExcludeRoutes.append(
                            NEIPv6Route(
                                destinationAddress: prefix.address(),
                                networkPrefixLength: NSNumber(value: prefix.prefix())
                            )
                        )
                    }
                }

                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
                settings.ipv6Settings = ipv6Settings
            }

            // 没有默认路由时必须把 DNS 限定到全域匹配，否则系统只在
            // 搜索域内使用隧道 DNS，分流规则会被绕过。
            let hasDefaultRoute = ipv4Routes.contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            if !hasDefaultRoute {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(
                address: options.getHTTPProxyServer(),
                port: Int(options.getHTTPProxyServerPort())
            )
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true

            var bypassDomains: [String] = []
            if let bypassIterator = options.getHTTPProxyBypassDomain() {
                while bypassIterator.hasNext() {
                    bypassDomains.append(bypassIterator.next())
                }
            }
            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }

            var matchDomains: [String] = []
            if let matchIterator = options.getHTTPProxyMatchDomain() {
                while matchIterator.hasNext() {
                    matchDomains.append(matchIterator.next())
                }
            }
            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            settings.proxySettings = proxySettings
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }
        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        guard tunFdFromLoop != -1 else {
            throw PendingNetTunnelError.message("无法取得 tun 文件描述符")
        }
        ret0_.pointee = tunFdFromLoop
    }

    // MARK: - 接口自动探测

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func autoDetectControl(_: Int32) throws {}

    func useProcFS() -> Bool {
        false
    }

    /// iOS 上没有可用的进程归属查询接口（那是 macOS root helper 的活）。
    func findConnectionOwner(
        _: Int32,
        sourceAddress _: String?,
        sourcePort _: Int32,
        destinationAddress _: String?,
        destinationPort _: Int32
    ) throws -> LibboxConnectionOwner {
        throw PendingNetTunnelError.message("iOS 不支持连接归属查询")
    }

    // MARK: - 默认接口监听

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        // libbox 要求这个调用返回时已经有一次接口状态，否则首个连接会
        // 在「默认接口未知」的状态下发出。
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                self.onUpdateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private func onUpdateDefaultInterface(
        _ listener: LibboxInterfaceUpdateListenerProtocol,
        _ path: Network.NWPath
    ) {
        guard path.status != .unsatisfied,
              let defaultInterface = path.availableInterfaces.first
        else {
            listener.updateDefaultInterface(
                "",
                interfaceIndex: -1,
                isExpensive: false,
                isConstrained: false
            )
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name,
            interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw PendingNetTunnelError.message("NWPathMonitor 尚未启动")
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    private final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    // MARK: - 其余平台能力

    func underNetworkExtension() -> Bool {
        true
    }

    /// includeAllNetworks 需要额外的 entitlement，本工程没有申请。
    func includeAllNetworks() -> Bool {
        false
    }

    func clearDNSCache() {
        guard let networkSettings else { return }
        runBlocking {
            self.tunnel.reasserting = true
            defer { self.tunnel.reasserting = false }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(nil) { _ in
                    continuation.resume()
                }
            }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in
                    continuation.resume()
                }
            }
        }
    }

    /// 读 SSID 需要 `com.apple.developer.networking.wifi-info`，本工程未申请；
    /// 生成的配置里也没有 wifi_ssid 规则，libbox 不会真的用到这个值。
    func readWIFIState() -> LibboxWIFIState? {
        nil
    }

    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        if !notification.openURL.isEmpty {
            content.userInfo["OPEN_URL"] = notification.openURL
            content.categoryIdentifier = "OPEN_URL"
        }
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try runBlocking {
            try await center.requestAuthorization(options: [.alert])
            try await center.add(request)
        }
    }

    /// 走 libbox 自带的 DNS 实现，不接管。
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    /// 用系统默认信任库即可。
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    // MARK: - LibboxCommandServerHandler

    func serviceStop() throws {
        tunnel.stopService()
    }

    func serviceReload() throws {
        try runBlocking { [self] in
            try await tunnel.reloadService()
        }
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let proxySettings = networkSettings?.proxySettings,
              proxySettings.httpServer != nil
        else {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings,
              let proxySettings = networkSettings.proxySettings,
              proxySettings.httpServer != nil,
              proxySettings.httpEnabled != isEnabled
        else {
            return
        }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxySettings
        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        Self.logger.debug("\(message, privacy: .public)")
    }

    // MARK: - 生命周期

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
    }
}

enum PendingNetTunnelError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text):
            return text
        }
    }
}

/// 把 async 工作桥回同步调用方。libbox 的平台协议全是同步的，
/// 而 NetworkExtension 的对应 API 是异步的，中间必须有这一层。
///
/// 用 `Task.detached` 而不是 `Task { }`：后者继承当前 actor／优先级，
/// 在已经被信号量阻塞的线程上排队会自锁。
func runBlocking<T>(_ block: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        let value = await block()
        box.result0 = value
        semaphore.signal()
    }
    semaphore.wait()
    return box.result0
}

func runBlocking<T>(_ tBlock: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do {
            let value = try await tBlock()
            box.result = .success(value)
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private final class ResultBox<T> {
    var result: Result<T, Error>!
    var result0: T!
}
