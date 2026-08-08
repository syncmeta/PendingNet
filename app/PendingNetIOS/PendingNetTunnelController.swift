import Foundation
@preconcurrency import NetworkExtension
import SBTallyCore

/// 驱动 Packet Tunnel Extension 的 App 侧控制器：安装/查找
/// `NETunnelProviderManager`、启停隧道、在隧道运行中热切换分流模式。
///
/// 配置内容随 `startTunnel` 的 options 下发给扩展，不写进
/// `providerConfiguration`——VPN profile 保存在系统 preferences
/// 数据库里，不具备 App Group 文件同等的数据保护属性，因此任何密钥或
/// 连接材料都不允许进入 `providerConfiguration`。扩展自己会在 libbox
/// 接受配置之后才把这份配置落盘为快照（见 `PacketTunnelProvider`），
/// 这个次序是故意的：本控制器不做重复的落盘，避免绕开这个保护。
@MainActor
final class PendingNetTunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid {
        didSet { syncCommandChannel() }
    }
    @Published var routeMode: PendingNetRouteMode = .global

    /// 当前 VPS 的 selector tag。由 `runtimeServer(name:)` 确定性生成，
    /// App 侧自己算得出来，不需要向扩展查询。
    @Published private(set) var selectorTag: String?
    /// selector 的可选成员，顺序由内核给出。
    @Published private(set) var outboundMembers: [String] = []
    /// selector 当前选中的出站。
    @Published private(set) var currentOutbound: String?
    /// 各成员最近一次 urltest 的延迟（毫秒）。0 表示还没有测速结果。
    @Published private(set) var outboundDelays: [String: Int] = [:]

    /// `start()` 因为规则集不可用而降级到全局时留下的提示。UI 取用后
    /// 自行清空——降级不是错误，`start()` 不能因此抛出。
    @Published var degradeNotice: String?

    /// 隧道在位。`.reasserting` 也算——Wi-Fi↔蜂窝切换时隧道并没有断，只是
    /// 内核在重新握手，此时控制通道仍然可用，把选择器藏起来反而是误导。
    var isTunnelLive: Bool {
        status == .connected || status == .reasserting
    }

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var commandClient: PendingNetCommandClient?
    private var isForeground = true

    private let tunnelBundleID = "com.pendingname.pendingnet.extension"
    private let routeModeKey = "pendingnet.ios.route-mode.v1"
    private let ruleSetStore: PendingNetRuleSetStore

    init(ruleSetStore: PendingNetRuleSetStore) {
        self.ruleSetStore = ruleSetStore
        // 经 `stored(rawValue:)` 读，而不是直接 `init(rawValue:)`：档位改名之后
        // 老用户存的还是 `bypassCN` / `direct`，直接解会读成 nil 并被悄悄打回
        // 全局，等于因为一次改名丢掉了用户的设置。顺手把迁移结果写回去，免得
        // 每次冷启动都再翻译一遍。
        if let raw = UserDefaults.standard.string(forKey: routeModeKey),
           let mode = PendingNetRouteMode.stored(rawValue: raw) {
            routeMode = mode
            if mode.rawValue != raw {
                PendingNetTunnelPaths.invalidateSnapshotForRemovedDirectMode(
                    storedRouteModeRawValue: raw,
                    in: PendingNetTunnelPaths.container()
                )
                UserDefaults.standard.set(mode.rawValue, forKey: routeModeKey)
            }
        }
        // 显式写标签：`PendingNetCommandClient` 现在有 onSnapshot / onLogEvent
        // 两个初始化器，尾随闭包会歧义。
        commandClient = PendingNetCommandClient(onSnapshot: { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        })
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        commandClient?.stop()
    }

    /// 查找系统里已安装的 PendingNet 隧道 profile（如果有）并订阅其状态。
    /// 找不到也不是错误——用户可能还没连过一次，`start` 会负责安装。
    func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let existing = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelBundleID
        }
        manager = existing
        status = existing?.connection.status ?? .invalid
        observeStatus()
    }

    /// 每次 manager 被替换（新装、reload 后 loadFromPreferences 换了实例）
    /// 都要先摘掉旧观察者再挂新的，否则要么漏订阅新状态，要么残留一个
    /// 指向旧 connection 的观察者。
    private func observeStatus() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = connection.status }
        }
    }

    /// 落地分流模式。
    ///
    /// 隧道**不在位**时还要顺手把 App Group 里的启动快照一起重写。少了这一步，
    /// `UserDefaults` 里是新模式、快照里还是旧模式，而快照正是「设置 → VPN」
    /// 里直接开隧道时扩展唯一能读到的配置（那条路径 `startTunnel` 的 options
    /// 是空的）——界面显示「白名单」、隧道实际跑「全局」，反过来也一样：
    /// 用户以为国内在直连，快照里却是全都走代理。
    ///
    /// 隧道在位时不写：那条路径由调用方 `reload()` 把新配置推给扩展，扩展在
    /// libbox **接受之后**才落盘快照，这个次序不能绕过。
    ///
    /// 这里写的是一份没有经过内核校验的配置，理论上可能毒化下一次冷启动。
    /// 权衡过：`PendingNetTunnelConfig.make` 的三种分流模式输出都有
    /// `testEveryRouteModePassesInstalledSingBoxCheck` 用真 sing-box 兜底，
    /// 而万一真被拒，失败是**可见**的（扩展会写 `last-error.txt`，隧道起不来），
    /// 用户打开 App 点一次连接就恢复；反过来「静默跑错模式」既看不见也不会自愈。
    func setRouteMode(
        _ mode: PendingNetRouteMode,
        profile: PendingNetNodeProfile,
        serverName: String
    ) {
        routeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: routeModeKey)
        guard !isTunnelLive else { return }
        guard let base = PendingNetTunnelPaths.container(),
              let content = try? makeConfigContent(profile: profile, serverName: serverName)
        else { return }
        // 写不成不是致命错误：下一次从 App 里 `start` 会带着 options 覆盖它。
        try? Data(content.utf8).write(
            to: PendingNetTunnelPaths.snapshotURL(in: base),
            options: .atomic
        )
    }

    // MARK: - 协议手选与测速

    /// 记下当前 VPS 的 selector tag。tag 只取决于 serverID，两侧算出来的
    /// 结果一致，所以 App 不必向扩展查询「隧道里那个 selector 叫什么」。
    func bindSelector(profile: PendingNetNodeProfile, serverName: String) {
        let tag = (try? profile.runtimeServer(name: serverName))?.selectorTag
        guard tag != selectorTag else { return }
        selectorTag = tag
        syncCommandChannel()
    }

    /// App 进入后台/回到前台。后台期间把分组流拆掉：扩展只有约 50MB 额度，
    /// 不该为一个没人看的界面每秒序列化一次分组。
    func setForeground(_ value: Bool) {
        guard isForeground != value else { return }
        isForeground = value
        syncCommandChannel()
    }

    /// 切换 selector 的当前出站。走 command client，隧道不重启、已有连接不断。
    func selectOutbound(_ tag: String) async throws {
        guard isTunnelLive, let selectorTag else {
            throw PendingNetCommandError.notConnected
        }
        try await PendingNetCommandClient.selectOutbound(
            groupTag: selectorTag,
            outboundTag: tag
        )
        // 乐观更新：分组推送最快也要等下一个推送间隔才到，下一帧就会被
        // 内核的真实状态覆盖（或纠正）。
        currentOutbound = tag
    }

    /// 触发一次分组测速。结果不在这里返回——内核测完之后，延迟随分组推送
    /// 落到 `outboundDelays`。
    func runURLTest() async throws {
        guard isTunnelLive, let selectorTag else {
            throw PendingNetCommandError.notConnected
        }
        try await PendingNetCommandClient.urlTest(groupTag: selectorTag)
    }

    /// 等 `outboundDelays` 真的变了，或者等到超时为止。
    ///
    /// `urlTest:` 只负责**触发**，测速结果是随下一轮分组推送异步到达的。
    /// UI 的「测速中」必须盖住这段等待，否则转圈在 RPC 返回的瞬间就停了、
    /// 数字却还没变，用户只会以为什么都没发生。
    func awaitDelayChange(
        from previous: [String: Int],
        timeout: TimeInterval = 8
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if outboundDelays != previous { return }
            try? await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
        }
    }

    private func apply(_ snapshot: PendingNetCommandClient.Snapshot) {
        outboundMembers = snapshot.members
        currentOutbound = snapshot.selected
        outboundDelays = snapshot.delays
    }

    /// 控制通道的生命周期跟随两件事：隧道是否在位，以及 App 是否在前台。
    ///
    /// - 隧道不在位（或还不知道 selector tag）：拆流**并清空**状态。留着
    ///   上一次的延迟数字会让断开的隧道看上去还连着。
    /// - 隧道在位但 App 在后台：只拆流，**不清空**。回到前台一秒内就会重新
    ///   订上，中间保留最后一次快照，免得切回来先闪一下空列表。
    private func syncCommandChannel() {
        guard isTunnelLive, let selectorTag else {
            commandClient?.stop()
            outboundMembers = []
            currentOutbound = nil
            outboundDelays = [:]
            return
        }
        guard isForeground else {
            commandClient?.stop()
            return
        }
        commandClient?.start(groupTag: selectorTag)
    }

    /// 生成配置并启动隧道。
    ///
    /// 启动前先确认 Keychain 里有设备令牌：没有令牌意味着配对已失效，
    /// 此时隧道即使起得来也拿不到后续的节点资料刷新，应当直接拦住并
    /// 要求重新配对，而不是让用户面对一条不会自愈的连接。
    func start(
        profile: PendingNetNodeProfile,
        serverName: String,
        serverID: String
    ) async throws {
        guard try PendingNetCredentialStore.load(serverID: serverID) != nil else {
            throw PendingNetPairingError.serverRejected("此设备没有找到 VPS 访问凭据，请重新配对")
        }
        // 控制通道要在隧道连上的那一刻就知道该订阅哪个 selector，不能等
        // 界面那边的绑定先跑。
        bindSelector(profile: profile, serverName: serverName)
        await ensureRouteModeIsRunnable(profile: profile, serverName: serverName)
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        let manager = try await installedManager()
        try manager.connection.startVPNTunnel(options: [
            "configContent": content as NSString,
        ])
    }

    /// 「规则集缺失或损坏时降级为全局，不使隧道启动失败」这条规则原先
    /// 只长在分流选择器那条路径上。持久化的白名单 / 黑名单走的是这里：直接
    /// 拿它生成配置，规则集不在（或上一轮落了个被替换的 HTML）就会产出一份
    /// 内核拒收的配置，隧道干脆起不来——正是那条规则要避免的结果。黑名单
    /// 同样吃规则集（geosite-gfw），所以判据是「不是全局」而不是某一档。
    ///
    /// 判据是 `ensureAvailable(for:)` 之后的 `isReady(for:)`，而不是它有没有
    /// 抛错：那是照磁盘上的文件（含 `.srs` 魔数）重新算出来的，就算下载
    /// 那一步「成功」了却没落下有效文件，这里也拦得住。两者都**按档位**取，
    /// 不看整体的 `isReady`——白名单不该因为它用不到的 geosite-gfw 缺失
    /// 而被降级。
    private func ensureRouteModeIsRunnable(
        profile: PendingNetNodeProfile,
        serverName: String
    ) async {
        guard routeMode != .global else { return }
        let mode = routeMode
        var reason: String?
        do {
            try await ruleSetStore.ensureAvailable(for: mode)
            if !ruleSetStore.isReady(for: mode) { reason = "规则集文件不完整或不是有效的 .srs" }
        } catch {
            reason = error.localizedDescription
        }
        guard let reason else { return }
        setRouteMode(.global, profile: profile, serverName: serverName)
        degradeNotice = "规则集不可用，本次已降级为全局：\(reason)"
    }

    func stop() async {
        manager?.connection.stopVPNTunnel()
    }

    /// Task 10 切换分流模式时调用：隧道已连接才有意义，未连接直接跳过——
    /// 新的分流模式会在下一次 `start` 里随配置一起生效。
    ///
    /// 一直等到扩展真正回了 `sendProviderMessage` 的 completion 才返回。
    /// 早先的版本消息一发出去就返回，`try await` 不抛错只代表「发送成功」，
    /// 不代表扩展接受了新配置——调用方没法据此判断分流模式是否真的切换了。
    /// completion 里回一个非空响应即代表扩展拒绝，这里把它转成错误抛出去，
    /// 而不是像之前那样只 `NSLog` 一声就当没发生过。
    ///
    /// `sendProviderMessage` 没有任何文档承诺 completion 一定会在有限时间
    /// 内调用（扩展卡住或被系统杀掉都可能让它永远不到），所以额外设了一个
    /// 宽松的超时，只代表「不再等它」，不代表扩展真的失败了。
    func reload(profile: PendingNetNodeProfile, serverName: String) async throws {
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        // 用 `isTunnelLive`（`.connected` 或 `.reasserting`）而不是单纯
        // `.connected`：调用方（Task 10 的分流模式切换）是照 `isTunnelLive`
        // 判断「隧道在位」再决定要不要 reload 的，两边判据不一致的后果是
        // reasserting 期间这里静默 return（不抛错），调用方却把它当成功——
        // 用户会看到「已切换」，但扩展根本没收到新配置。控制通道本身在
        // reasserting 期间是可用的（`selectOutbound`/`runURLTest` 用的也是
        // 同一个前提），`sendProviderMessage` 没有理由是例外。
        //
        // 判据不成立时**抛错**而不是 `return`：调用方在自己的 guard 与这次
        // 调用之间隧道断掉是一条窄但真实的竞态，静默返回等于告诉调用方
        // 「已切换」，而扩展根本没收到新配置——正是上一轮修掉的那类 bug。
        guard isTunnelLive, let session = manager?.connection as? NETunnelProviderSession else {
            throw PendingNetCommandError.notConnected
        }

        let gate = ReloadResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.arm(continuation)
            do {
                try session.sendProviderMessage(Data(content.utf8)) { response in
                    if let response, let text = String(data: response, encoding: .utf8), !text.isEmpty {
                        NSLog("[PendingNet] reload rejected: %@", text)
                        gate.resume(.failure(PendingNetCommandError.reloadRejected(text)))
                    } else {
                        gate.resume(.success(()))
                    }
                }
            } catch {
                gate.resume(.failure(error))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                gate.resume(.failure(PendingNetCommandError.timedOut))
            }
        }
    }

    /// 只放行第一次 resume；`sendProviderMessage` 的 completion 与超时块
    /// 都可能先到，`PendingNetCommandClient.ResumeGate` 是同一个模式。
    private final class ReloadResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        func arm(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            switch result {
            case .success: pending.resume()
            case .failure(let error): pending.resume(throwing: error)
            }
        }
    }

    private func makeConfigContent(
        profile: PendingNetNodeProfile,
        serverName: String
    ) throws -> String {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: try profile.runtimeServer(name: serverName),
            routeMode: routeMode,
            ruleSetDirectory: PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            cachePath: PendingNetTunnelPaths.cacheURL(in: base).path
        )
        // 仅用于真机排查「App 生成的配置到底长什么样」的调试留痕，
        // 不是配置传递给扩展的机制——扩展永远只认 startTunnel 的
        // options（或它自己落的快照），不读这个文件。就算这次写入
        // 失败也不影响隧道启动，因此这里不检查返回值、不抛错。
        try? data.write(to: PendingNetTunnelPaths.configURL(in: base), options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }

    private func installedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "PendingNet"
        // 只放版本号，任何密钥或连接材料都不进 VPN profile。这个字段本身
        // 也不参与任何比对逻辑——配置更新走 options 下发 + sendProviderMessage
        // 主动 reload，版本号纯粹是占位。
        proto.providerConfiguration = ["configVersion": 1]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "PendingNet"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observeStatus()
        return manager
    }
}
