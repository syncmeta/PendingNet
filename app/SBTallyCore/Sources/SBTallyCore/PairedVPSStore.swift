import Foundation

/// 一台已配对的 VPS。macOS 与 iOS 共用同一份形状 —— 之前两端各存各的，
/// 字段还对不齐，iCloud 一同步就会互相看不懂。
public struct PairedVPSRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { serverID }
    public var serverID: String
    public var name: String
    public var endpoint: String
    public var certificateSHA256: String
    public var deviceID: String
    public var capabilities: [String]
    /// 节点资料拉到之后填上，供「详情」展示。可选，老版本存档里没有这一项。
    public var nodeProtocols: [String]?
    public var pairedAt: Date
    /// 这条记录最后一次被改动的时刻，跨设备合并时用它做 last-writer-wins。
    /// 老存档里没有这一项，解码时退回 `pairedAt`。
    public var updatedAt: Date

    public init(
        serverID: String,
        name: String,
        endpoint: String,
        certificateSHA256: String,
        deviceID: String,
        capabilities: [String],
        nodeProtocols: [String]? = nil,
        pairedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.serverID = serverID
        self.name = name
        self.endpoint = endpoint
        self.certificateSHA256 = certificateSHA256
        self.deviceID = deviceID
        self.capabilities = capabilities
        self.nodeProtocols = nodeProtocols
        self.pairedAt = pairedAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decode(String.self, forKey: .serverID)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        certificateSHA256 = try container.decode(String.self, forKey: .certificateSHA256)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        nodeProtocols = try container.decodeIfPresent([String].self, forKey: .nodeProtocols)
        // iOS 的老记录连 pairedAt 都没有；给个最早的时刻，让任何带真实时间戳的
        // 记录都能赢过它，而不是把老记录当成「刚刚改过」压住对面的新数据。
        pairedAt = try container.decodeIfPresent(Date.self, forKey: .pairedAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? pairedAt
    }

    /// 界面上代表这台 VPS 的就是它的 IP（或主机名）—— 不带协议、不带端口。
    public var address: String {
        if let host = URL(string: endpoint)?.host, !host.isEmpty { return host }
        var text = endpoint
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let colon = text.lastIndex(of: ":") { text = String(text[text.startIndex..<colon]) }
        return text
    }

    /// 控制服务端口，只在「详情」里出现。
    public var controlPort: String? {
        if let port = URL(string: endpoint)?.port { return String(port) }
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let tail = String(endpoint[endpoint.index(after: colon)...])
        return Int(tail) == nil ? nil : tail
    }
}

public enum PairedVPSMerge {
    /// 按 serverID 取并集，同一台以 `updatedAt` 新的那份为准；打平手时留本地的
    /// （不然每次开机两边互相覆盖，列表会无谓地抖）。
    ///
    /// 故意不做「删除」：现在两端都没有删除已配对 VPS 的入口，做成并集就不会
    /// 出现「一台设备上的旧存档把另一台刚配好的 VPS 顶掉」。将来真要支持删除，
    /// 得在记录里加墓碑位，不能靠缺席来表达。
    public static func merge(local: [PairedVPSRecord], remote: [PairedVPSRecord]) -> [PairedVPSRecord] {
        var byID: [String: PairedVPSRecord] = [:]
        for record in local {
            byID[record.serverID] = record
        }
        for record in remote {
            guard let existing = byID[record.serverID] else {
                byID[record.serverID] = record
                continue
            }
            if record.updatedAt > existing.updatedAt {
                byID[record.serverID] = record
            }
        }
        return sorted(Array(byID.values))
    }

    /// 名字排序；同名再按 serverID，保证两端拿到的顺序一致。
    public static func sorted(_ records: [PairedVPSRecord]) -> [PairedVPSRecord] {
        records.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.serverID < $1.serverID
        }
    }
}

/// `NSUbiquitousKeyValueStore` 的注入点（单测用假实现）。
public protocol UbiquitousKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {
    public func setData(_ data: Data?, forKey key: String) {
        if let data {
            set(data, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }
}

/// 两端共用的「已配对 VPS」存储。
///
/// 真源是 iCloud 键值存储，本地 `UserDefaults` 是镜像兼离线兜底。iCloud 用不了
/// （没登 iCloud、entitlement 没生效、本地 ad-hoc 签名的开发构建）时整个云那半边
/// 直接不存在，一切照旧纯本地工作，不报错、不提示。
@MainActor
public final class PairedVPSStore: ObservableObject {
    public nonisolated static let defaultLocalKey = "pendingnet.paired-vps.v1"
    public nonisolated static let defaultCloudKey = "pendingnet.paired-vps.v1"

    @Published public private(set) var servers: [PairedVPSRecord] = []
    /// iCloud 那边推过来变更时调用（界面据此刷新选中项等派生状态）。
    public var onExternalChange: (() -> Void)?

    /// 这台设备上 iCloud 键值存储是否真的可用。界面不该拿它去提示什么，
    /// 留着是为了排查问题。
    public var isCloudAvailable: Bool { cloud != nil }

    private let defaults: UserDefaults
    private let cloud: UbiquitousKeyValueStoring?
    private let localKey: String
    private let cloudKey: String
    private let now: () -> Date
    private var observer: NSObjectProtocol?

    public init(
        defaults: UserDefaults = .standard,
        cloud: UbiquitousKeyValueStoring? = PairedVPSStore.makeCloudStoreIfAvailable(),
        localKey: String = PairedVPSStore.defaultLocalKey,
        cloudKey: String = PairedVPSStore.defaultCloudKey,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.localKey = localKey
        self.cloudKey = cloudKey
        self.now = now
        servers = PairedVPSMerge.merge(local: decode(defaults.data(forKey: localKey)), remote: cloudRecords())
        persist()
        observeCloud()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// `NSUbiquitousKeyValueStore.default` 在没有 entitlement 时不会崩，只是
    /// 什么也同步不了；`synchronize()` 返回 false 正是官方的可用性探针。探不通
    /// 就当 iCloud 不存在，调用方不用再判断。
    public nonisolated static func makeCloudStoreIfAvailable() -> UbiquitousKeyValueStoring? {
        let store = NSUbiquitousKeyValueStore.default
        return store.synchronize() ? store : nil
    }

    // MARK: - 写

    /// 新增或就地更新一台 VPS，并盖上新的 `updatedAt`（本设备成为最新写者）。
    public func upsert(_ record: PairedVPSRecord) {
        var stamped = record
        stamped.updatedAt = now()
        var next = servers.filter { $0.serverID != stamped.serverID }
        next.append(stamped)
        servers = PairedVPSMerge.sorted(next)
        persist()
    }

    /// 把两端各自的老存档并进来。老记录不盖新时间戳 —— 它们本来就不知道自己
    /// 是什么时候写的，盖上「现在」会让它压住对面真正更新的那一份。
    public func adoptLegacy(_ records: [PairedVPSRecord]) {
        guard !records.isEmpty else { return }
        let merged = PairedVPSMerge.merge(local: servers, remote: records)
        guard merged != servers else { return }
        servers = merged
        persist()
    }

    // MARK: - 读

    /// 启动 / 回到前台时叫一次：先把 iCloud 那边拉新，再合并。
    public func refreshFromCloud() {
        cloud?.synchronize()
        mergeCloudIntoLocal()
    }

    private func observeCloud() {
        guard cloud != nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mergeCloudIntoLocal()
                self.onExternalChange?()
            }
        }
    }

    private func mergeCloudIntoLocal() {
        let merged = PairedVPSMerge.merge(local: servers, remote: cloudRecords())
        guard merged != servers else { return }
        servers = merged
        persist()
    }

    private func cloudRecords() -> [PairedVPSRecord] {
        guard let cloud else { return [] }
        return decode(cloud.data(forKey: cloudKey))
    }

    private func decode(_ data: Data?) -> [PairedVPSRecord] {
        guard let data,
              let decoded = try? JSONDecoder().decode([PairedVPSRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: localKey)
        cloud?.setData(data, forKey: cloudKey)
    }
}
