import Foundation
import Libbox
import SBTallyCore

enum PendingNetCommandError: LocalizedError, Equatable {
    case setup(String)
    case unavailable
    case notConnected
    case timedOut
    case reloadRejected(String)

    var errorDescription: String? {
        switch self {
        case .setup(let reason): "无法接入隧道控制通道：\(reason)"
        case .unavailable: "无法创建隧道控制通道"
        case .notConnected: "隧道未连接，无法切换协议或测速"
        case .timedOut: "隧道控制通道无响应，请稍后重试"
        case .reloadRejected(let reason): "扩展拒绝了新配置：\(reason)"
        }
    }
}

/// 主 App 与扩展内 sing-box 之间的控制通道。
///
/// 走的是 libbox 自己的 command socket——一个开在 App Group 目录里的
/// unix socket，由 `LibboxSetup` 的 `basePath` 定位（扩展在 `startTunnel`
/// 里用同一个目录调用过一次）。因此 selector 切换与 urltest **不经过**
/// `sendProviderMessage`，也就不需要重启隧道、不打断已建立的连接；
/// `sendProviderMessage` 在本项目里只用于换配置。
///
/// 本类型有两条互不相干的路径：
/// - 订阅：长连接的 `LibboxCommandClient`，每个实例只订阅一种命令
///   （`LibboxCommandGroup` 或 `LibboxCommandLog`），由 `Subscription` 决定。
/// - 动作：`LibboxNewStandaloneCommandClient()` 的一次性调用，
///   `selectOutbound:outboundTag:error:` 在本版本 libbox 里是同步阻塞的，
///   所以放到后台队列执行。
///
/// 一个实例同一时刻只维持一条连接，所以「分组」和「日志」要两个实例。
/// 分组订阅常驻（隧道在位 + App 在前台），日志订阅只在日志页打开时存在——
/// 扩展只有约 50MB 额度，不该为一个没人看的页面持续序列化日志。
final class PendingNetCommandClient: NSObject {
    /// 一个实例订阅什么。
    enum Subscription: Equatable {
        /// 某个 selector 的分组状态（成员名单 + 当前选中项）。
        case groups(tag: String)
        /// sing-box 内核日志。
        ///
        /// 这是内核日志**唯一**的出口：libbox 有 platform interface 时会把
        /// `defaultLogWriter` 设成 `io.Discard`，日志只进 command server 的
        /// 环形缓冲。扩展那边的 stderr.log 里没有它们。
        case logs
    }

    /// 日志订阅推上来的事件。`append` 与 `clear` 必须分开——用「空数组表示
    /// 清空」会和「这一批没有新行」混成一件事。
    enum LogEvent: Equatable {
        case append([String])
        case clear
    }

    /// selector 的一次快照。成员顺序按内核给出的顺序，不重排。
    ///
    /// 刻意**不**带各成员的 urltest 延迟：那是按协议出数，和「一台 VPS 一个
    /// 延迟」的口径打架（见 `PendingNetLatencyTarget`）。内核自己的 urltest
    /// 照旧跑，只是不再端到用户面前。
    struct Snapshot: Equatable {
        var members: [String] = []
        var selected: String?
    }

    // MARK: - 进程级 libbox 初始化

    private static let setupLock = NSLock()
    private static var setupOutcome: Result<Void, PendingNetCommandError>?

    /// command client 靠 `LibboxSetup` 落下的 basePath 找到扩展开的
    /// command socket，所以 App 侧必须用与扩展**完全相同**的目录调用一次。
    /// 路径一律取自 `PendingNetTunnelPaths`，两侧不得各写各的。
    ///
    /// libbox 的 setup 是进程级全局状态，只做一次。失败结果同样缓存：
    /// 唯一的失败原因是拿不到 App Group 容器，重试不会有不同结果。
    static func setupLibbox() throws {
        setupLock.lock()
        defer { setupLock.unlock() }
        if let setupOutcome {
            return try setupOutcome.get()
        }
        let outcome: Result<Void, PendingNetCommandError>
        if let base = PendingNetTunnelPaths.container() {
            let options = LibboxSetupOptions()
            // 扩展侧 basePath 与 workingPath 都是容器根目录；两个字段都对齐，
            // 免得依赖「socket 到底挂在哪个字段下」这种未写进头文件的细节。
            options.basePath = base.path
            options.workingPath = base.path
            options.tempPath = NSTemporaryDirectory()
            // App 侧不订阅 log 命令，环形缓冲给个下限就行。
            // 这是 App 进程自己的环形缓冲；App 侧没有 command server，日志
            // 缓冲是扩展那边 `logMaxLines` 的事，这里给个下限就行。
            options.logMaxLines = 100
            options.debug = false
            var error: NSError?
            outcome = LibboxSetup(options, &error)
                ? .success(())
                : .failure(.setup(error?.localizedDescription ?? "未知原因"))
        } else {
            outcome = .failure(.setup("无法访问 App Group 容器"))
        }
        setupOutcome = outcome
        return try outcome.get()
    }

    // MARK: - 动作（一次性调用）

    /// 切换 selector 的当前出站。
    static func selectOutbound(groupTag: String, outboundTag: String) async throws {
        try await perform { try $0.selectOutbound(groupTag, outboundTag: outboundTag) }
    }

    /// 本版本 libbox 的这两个调用是同步阻塞的（`BOOL ... error:` 形态，
    /// 不是回调），必须离开主线程，否则连不上扩展时会卡住 UI。
    ///
    /// 底层调用**不可取消**，`withCheckedThrowingContinuation` 也不参与
    /// 任务取消：真挂住了就再也不会回来，调用方的「切换中/测速中」标志会
    /// 永远留着。所以这里自己设一个超时——超时只代表「不再等它」，后台
    /// 线程仍会自己跑完，`ResumeGate` 保证 continuation 只被 resume 一次。
    private static func perform(
        timeout: TimeInterval = 10,
        _ body: @escaping (LibboxCommandClient) throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try setupLibbox()
                    guard let client = LibboxNewStandaloneCommandClient() else {
                        throw PendingNetCommandError.unavailable
                    }
                    try body(client)
                    gate.resume(nil)
                } catch {
                    gate.resume(error)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resume(PendingNetCommandError.timedOut)
            }
        }
    }

    /// 只放行第一次 resume。两条路径（真结果 / 超时）都可能先到。
    /// 唯一的可变状态由 `lock` 保护，跨线程传递是安全的。
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ error: Error?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            if let error {
                pending.resume(throwing: error)
            } else {
                pending.resume()
            }
        }
    }

    // MARK: - 订阅（长连接）

    /// 所有可变状态都只在这个队列上读写；回调统一在主线程投递。
    private let queue = DispatchQueue(label: "com.pendingname.pendingnet.command-client")
    private var client: LibboxCommandClient?
    /// 每次建/拆连接都自增。旧 client 的回调靠它被识别并丢弃——libbox 持有
    /// handler，断开之后仍可能有在途回调。
    private var generation: UInt64 = 0
    private var wantsConnection = false
    private var subscription: Subscription?
    private var retryCount = 0

    private let onSnapshot: ((Snapshot) -> Void)?
    private let onLogEvent: ((LogEvent) -> Void)?

    /// - Parameter onSnapshot: 在主线程调用。
    init(onSnapshot: @escaping (Snapshot) -> Void) {
        self.onSnapshot = onSnapshot
        onLogEvent = nil
        super.init()
    }

    /// - Parameter onLogEvent: 在主线程调用。
    init(onLogEvent: @escaping (LogEvent) -> Void) {
        self.onLogEvent = onLogEvent
        onSnapshot = nil
        super.init()
    }

    /// 订阅某个 selector 的分组状态。重复调用同一个 tag 是空操作，
    /// 因此可以安全地挂在每一次隧道状态变化上。
    func start(groupTag: String) {
        start(.groups(tag: groupTag))
    }

    /// 订阅内核日志。同样幂等。
    func startLogs() {
        start(.logs)
    }

    private func start(_ wanted: Subscription) {
        queue.async {
            if self.wantsConnection, self.subscription == wanted { return }
            self.tearDown()
            self.wantsConnection = true
            self.subscription = wanted
            self.retryCount = 0
            self.openConnection()
        }
    }

    func stop() {
        queue.async {
            self.wantsConnection = false
            self.subscription = nil
            self.tearDown()
        }
    }

    // MARK: 队列内部

    private func tearDown() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        if let client {
            try? client.disconnect()
            self.client = nil
        }
    }

    /// 幂等：已经有一条活着的连接就什么都不做。少了 `client == nil` 这一条，
    /// 两个各自合法的重连（比如失败重连与 `disconnected:` 触发的重连）会
    /// 各建一条连接，后者把前者从 `client` 里挤掉且不 disconnect——被挤掉
    /// 的那条仍然是一路活着的 `SubscribeGroups` 流，扩展会继续往里序列化
    /// 分组，而扩展只有约 50MB 额度。回调侧的 token 校验会把它的推送丢掉，
    /// 所以这种泄漏是**静默**的，只表现为扩展内存增长直至被 jetsam 干掉。
    private func openConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard wantsConnection, client == nil, let subscription else { return }
        // setup 失败是永久性的（拿不到 App Group 容器），重试没有意义。
        guard (try? Self.setupLibbox()) != nil else { return }

        generation &+= 1
        let token = generation

        let options = LibboxCommandClientOptions()
        // 一个实例只订一种命令：状态、连接列表都不是本项目需要的，订多了
        // 白白占扩展那 50MB 的额度。两种命令各自走自己的流（服务端的
        // `SubscribeGroups` / `SubscribeLogs`），都不依赖 status 通道。
        switch subscription {
        case .groups: options.addCommand(LibboxCommandGroup)
        case .logs: options.addCommand(LibboxCommandLog)
        }
        // 注意：这个间隔只作用于 status 与 connections 两条流
        // （`SubscribeStatusRequest.GetInterval` / `SubscribeConnectionsRequest.GetInterval`），
        // `SubscribeGroupsRequest` 根本没有 interval 字段——调它不会改变
        // 分组推送的节奏。留着只是给一个正常值，别指望调它有效果。
        options.statusInterval = Int64(NSEC_PER_SEC)

        guard let client = LibboxNewCommandClient(
            Handler(owner: self, token: token, subscription: subscription),
            options
        ) else {
            scheduleRetry()
            return
        }
        do {
            try client.connect()
        } catch {
            try? client.disconnect()
            // 这条已经废了：让它的 handler 回调不再被采纳，也让上一步排的
            // 重试（如果有）失效，保证同一时刻只有一个待执行的重连。
            generation &+= 1
            // 隧道刚起来时扩展的 command server 可能还没就位，退避重试。
            scheduleRetry()
            return
        }
        self.client = client
        // 不能只靠 `connected()` 回调归零退避：libbox 若连上了却没回调，
        // 退避会一直钉在 15 秒。
        retryCount = 0
    }

    /// 指数退避重连，不设次数上限：重连只在 `wantsConnection` 为真时继续，
    /// 而它随隧道断开立刻变假，所以循环不会活过隧道。设次数上限反而更糟——
    /// 用完之后 UI 会永久停在「没有成员」，用户除了重启隧道无从恢复。
    ///
    /// 重试块和回调一样带 token：中途发生过 `stop()` / `tearDown()` /
    /// 连接失败的这一批重试必须作废，否则会叠出多条连接。
    private func scheduleRetry() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard wantsConnection else { return }
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), 15)
        let token = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.generation else { return }
            self.openConnection()
        }
    }

    private func handleConnected(token: UInt64) {
        queue.async {
            guard token == self.generation else { return }
            self.retryCount = 0
        }
    }

    private func handleDisconnected(token: UInt64) {
        queue.async {
            guard token == self.generation, self.wantsConnection else { return }
            self.tearDown()
            self.scheduleRetry()
        }
    }

    private func handleSnapshot(_ snapshot: Snapshot, token: UInt64) {
        queue.async {
            guard token == self.generation, self.wantsConnection,
                  let deliver = self.onSnapshot else { return }
            DispatchQueue.main.async { deliver(snapshot) }
        }
    }

    private func handleLogEvent(_ event: LogEvent, token: UInt64) {
        queue.async {
            guard token == self.generation, self.wantsConnection,
                  let deliver = self.onLogEvent else { return }
            DispatchQueue.main.async { deliver(event) }
        }
    }

    // MARK: - libbox 回调

    /// 本版本 libbox 的 `LibboxCommandClientHandler` 协议没有可选方法，
    /// 十个全都要实现——用不上的空着即可（每个实例只订一种命令，其余命令
    /// 的回调根本不会被触发）。
    private final class Handler: NSObject, LibboxCommandClientHandlerProtocol {
        private weak var owner: PendingNetCommandClient?
        private let token: UInt64
        private let subscription: Subscription

        init(owner: PendingNetCommandClient, token: UInt64, subscription: Subscription) {
            self.owner = owner
            self.token = token
            self.subscription = subscription
            super.init()
        }

        func connected() {
            owner?.handleConnected(token: token)
        }

        func disconnected(_ message: String?) {
            if let message, !message.isEmpty {
                NSLog("[PendingNet] command client disconnected: %@", message)
            }
            owner?.handleDisconnected(token: token)
        }

        func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {
            guard let message, let owner,
                  case .groups(let groupTag) = subscription else { return }
            var snapshot: Snapshot?
            while message.hasNext() {
                guard let group = message.next() else { continue }
                // 内核会把所有分组都推上来（含 `<selector>-mix` 这个 urltest
                // 分组），只取我们这台 VPS 的 selector。
                guard group.tag == groupTag else { continue }
                var found = Snapshot()
                found.selected = group.selected.isEmpty ? nil : group.selected
                if let items = group.getItems() {
                    while items.hasNext() {
                        guard let item = items.next() else { continue }
                        found.members.append(item.tag)
                    }
                }
                snapshot = found
            }
            guard let snapshot else { return }
            owner.handleSnapshot(snapshot, token: token)
        }

        /// 内核推来的一批日志行。连上时会先把环形缓冲里已有的整批回放一次，
        /// 之后才是增量——所以刚打开日志页就能看到隧道启动那几行。
        func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {
            guard let messageList, let owner, subscription == .logs else { return }
            var lines: [String] = []
            while messageList.hasNext() {
                guard let entry = messageList.next() else { continue }
                lines.append(entry.message)
            }
            guard !lines.isEmpty else { return }
            owner.handleLogEvent(.append(lines), token: token)
        }

        /// 内核要求订阅方清空自己那份日志（`ClearLogs` 之后）。
        func clearLogs() {
            guard let owner, subscription == .logs else { return }
            owner.handleLogEvent(.clear, token: token)
        }

        // 以下命令没有订阅，回调不会到达；留空实现只为满足协议。
        func setDefaultLogLevel(_: Int32) {}
        func writeStatus(_: LibboxStatusMessage?) {}
        // 头文件里的 selector 是 `writeConnectionEvents:`，但 Swift 侧导入成
        // `write(_:)`（编译器按重命名规则改写）。以编译器为准。
        func write(_: LibboxConnectionEvents?) {}
        func initializeClashMode(_: LibboxStringIteratorProtocol?, currentMode _: String?) {}
        func updateClashMode(_: String?) {}
    }
}
