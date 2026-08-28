import Foundation
import Security
import os

/// 设备令牌的存放位置。
///
/// 方案 A（Mac 与 iPhone 共用同一份设备凭据）要求令牌能经 iCloud 钥匙串在两台
/// 设备之间流动，但**不能**以「同步不了就报错」为代价：本地 ad-hoc 签名的开发
/// 构建既没有 keychain access group、也没有数据保护钥匙串的权限，那种情况下必须
/// 悄悄退回到今天的行为（普通 file-based 钥匙串，纯本地）。
///
/// 于是这里把「放哪」抽成一串按优先级排列的候选位置：写的时候从最好的开始试，
/// 第一个成功的就是这台设备当前能用的最好位置；读的时候按同一顺序找，找到的
/// 位置比当前能写的最好位置差，就顺手迁移上去（迁移成功才删旧的——写失败时
/// 宁可留着两份，也不能把老用户的配对弄丢）。
public struct PendingNetKeychainLocation: Equatable, Sendable {
    /// macOS 上是否走数据保护钥匙串（iOS 上恒为数据保护钥匙串，这一位无副作用）。
    /// iCloud 同步只有数据保护钥匙串支持。
    public var dataProtection: Bool
    /// 是否是 iCloud 同步条目。
    public var synchronizable: Bool
    /// 共享 keychain access group；nil = 用 App 默认组。
    public var accessGroup: String?

    public init(dataProtection: Bool, synchronizable: Bool, accessGroup: String?) {
        self.dataProtection = dataProtection
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
    }

    /// 按这个位置发出去的查询，会不会**顺带命中** `other` 位置上的条目。
    ///
    /// 关键在于 `accessGroup == nil` 不是「App 默认组」这么一个具体的组，而是
    /// **通配**：不带 `kSecAttrAccessGroup` 的查询会横扫这个 App 有权访问的所有
    /// 组，共享组也在里面。而有 entitlement 的构建里，共享组**就是** App 的默认
    /// 组（entitlements 里只有它一个），两档本来就落在同一个条目上。
    ///
    /// 清理更差的位置之前必须先问一句这个，否则就是「写进共享组 → 按默认组去
    /// 清理 → 把刚写的那条删掉」。0.3.21 踩的就是这个：`save` 报成功、事后三档
    /// 一条不剩，令牌永远搬不上能同步的位置，另一台设备上的 VPS 全是死的。
    func mayMatch(_ other: PendingNetKeychainLocation) -> Bool {
        guard dataProtection == other.dataProtection,
              synchronizable == other.synchronizable else { return false }
        // 组没写明 = 通配，什么组都命中；写明了就只命中同一个组。
        guard let accessGroup else { return true }
        return accessGroup == other.accessGroup
    }
}

/// 一台 VPS 的令牌在这台设备上的处境。
public enum PendingNetCredentialPromotion: Equatable, Sendable {
    /// 这台设备根本没有这一台的令牌。iCloud 只同步 VPS 记录，令牌走钥匙串，
    /// 两条链是分开的——记录到了、令牌没到，这一条就是这个状态。
    case notStored
    /// 令牌在能经 iCloud 钥匙串同步的位置上（本来就在，或者刚被搬上去）。
    case synchronizable
    /// 令牌在，但只能留在本机：这台设备用得了，别的设备看不到。
    /// 带上钥匙串状态码（`nil` = 没报错，纯粹是这个构建够不着同步位）。
    case localOnly(OSStatus?)
    /// 钥匙串读不了，说不准。**不等于没有令牌**——照这个结论去要求用户重新
    /// 配对，会白丢一次好好的配对。
    case unreadable(OSStatus?)
}

/// SecItem 的注入点。真机走 `SecItemKeychainBackend`，单测走内存假实现——
/// 未签名的测试二进制碰不到真钥匙串，迁移逻辑只能这样才测得到。
public protocol PendingNetKeychainBackend: Sendable {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

public struct SecItemKeychainBackend: PendingNetKeychainBackend {
    public init() {}

    public func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [CFString: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// 令牌读写的全部逻辑（可注入后端，便于单测）。
public struct PendingNetCredentialStoreCore: Sendable {
    public let service: String
    public let locations: [PendingNetKeychainLocation]
    private let backend: PendingNetKeychainBackend

    public init(
        service: String,
        locations: [PendingNetKeychainLocation],
        backend: PendingNetKeychainBackend
    ) {
        self.service = service
        self.locations = locations
        self.backend = backend
    }

    // MARK: - 写

    public func save(accessToken: String, serverID: String) throws {
        let outcome = try write(accessToken: accessToken, serverID: serverID)
        clearLocations(worseThan: outcome.index, serverID: serverID)
    }

    /// 令牌最终落在哪一档，以及**为什么没能更靠前**。
    private struct WriteOutcome {
        var index: Int
        /// 挡在前面那一档回的状态码。`nil` = 没有更好的一档被拒，写进的就是
        /// 理论上最好的位置。搬不上同步位时，用户能看见的原因就是它。
        var blockedBy: OSStatus?
    }

    /// 把更差位置上的旧条目清掉，免得读的时候被旧值挡住。
    ///
    /// **会命中刚写进去那条的位置一律跳过**——见 `mayMatch`。宁可留一份读不到
    /// 的残留（下一档的查询本来就找不到它），也绝不能把用户唯一那份令牌删掉。
    private func clearLocations(worseThan best: Int, serverID: String) {
        let winner = locations[best]
        for location in locations.dropFirst(best + 1) where !location.mayMatch(winner) {
            _ = backend.delete(query(for: location, serverID: serverID))
        }
    }

    /// 写进能用的最好位置；全都写不进去就抛错。
    private func write(accessToken: String, serverID: String) throws -> WriteOutcome {
        let tokenData = Data(accessToken.utf8)
        var lastStatus: OSStatus = errSecSuccess
        var firstRefusal: OSStatus?
        for (index, location) in locations.enumerated() {
            let status = write(tokenData, serverID: serverID, to: location)
            if status == errSecSuccess {
                return WriteOutcome(index: index, blockedBy: firstRefusal)
            }
            if firstRefusal == nil { firstRefusal = status }
            lastStatus = status
        }
        throw PendingNetPairingError.keychain(lastStatus)
    }

    private func write(_ tokenData: Data, serverID: String, to location: PendingNetKeychainLocation) -> OSStatus {
        let base = query(for: location, serverID: serverID)
        let updateStatus = backend.update(base, attributes: [kSecValueData: tokenData])
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var add = base
        add[kSecValueData] = tokenData
        if location.synchronizable || location.dataProtection {
            // 同步条目必须给可访问性，否则设备锁着就同步不过来。
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        }
        return backend.add(add)
    }

    // MARK: - 读（顺带迁移）

    public func load(serverID: String) throws -> String? {
        guard let found = try locate(serverID: serverID) else { return nil }
        if found.index > 0 {
            migrate(token: found.token, serverID: serverID, foundAt: found.index)
        }
        return found.token
    }

    /// 令牌在哪一档、内容是什么。只读，不迁移。
    private func locate(serverID: String) throws -> (index: Int, token: String)? {
        var missingEntitlementFailure: OSStatus?
        var hardFailure: OSStatus?
        var foundAccessibleEmptyLocation = false
        for (index, location) in locations.enumerated() {
            var find = query(for: location, serverID: serverID)
            find[kSecReturnData] = true
            find[kSecMatchLimit] = kSecMatchLimitOne
            let (status, data) = backend.copyMatching(find)
            if status == errSecItemNotFound {
                foundAccessibleEmptyLocation = true
                continue
            }
            guard status == errSecSuccess,
                  let data,
                  let token = String(data: data, encoding: .utf8) else {
                if status == errSecMissingEntitlement {
                    missingEntitlementFailure = status
                } else {
                    hardFailure = status
                }
                continue
            }
            return (index, token)
        }
        if let hardFailure { throw PendingNetPairingError.keychain(hardFailure) }
        // A development build commonly cannot query the synchronizable slots
        // (-34018) but can query the legacy local slot. If that accessible slot
        // explicitly says "not found", the credential is absent; surfacing the
        // entitlement error would misdiagnose it as a broken keychain.
        if foundAccessibleEmptyLocation { return nil }
        if let missingEntitlementFailure {
            throw PendingNetPairingError.keychain(missingEntitlementFailure)
        }
        return nil
    }

    // MARK: - 搬迁（启动时主动跑一次，不等到读）

    /// 把这一台 VPS 的令牌搬到当前能用的最好位置，并说清结果。
    ///
    /// 和 `load` 顺带做的那次迁移是同一件事，区别在于**主动**：迁移只在有人读
    /// 令牌时才发生，而读只发生在用户点某台 VPS 的时候——0.3.21 那批卡在老位置
    /// 上的令牌因此可以一直卡着，直到用户在这台设备上主动去点一下才被搬。
    /// 启动时跑一遍，同步这件事才不用等用户先做点什么。
    public func promote(serverID: String) -> PendingNetCredentialPromotion {
        let found: (index: Int, token: String)?
        do {
            found = try locate(serverID: serverID)
        } catch {
            return .unreadable(status(of: error))
        }
        guard let found else { return .notStored }
        if locations[found.index].synchronizable { return .synchronizable }

        // 在够不着 iCloud 的那一档上，试着往上搬。
        do {
            let outcome = try write(accessToken: found.token, serverID: serverID)
            clearLocations(worseThan: outcome.index, serverID: serverID)
            return locations[outcome.index].synchronizable
                ? .synchronizable
                : .localOnly(outcome.blockedBy)
        } catch {
            // 无损：写不进去就原地不动，老条目照旧留着，令牌照常读得到。
            return .localOnly(status(of: error))
        }
    }

    private func status(of error: Error) -> OSStatus? {
        guard case .keychain(let status)? = error as? PendingNetPairingError else { return nil }
        return status
    }

    /// 把在 `foundAt` 找到的老条目搬到当前能用的最好位置。
    ///
    /// 无损是硬要求：写不进去（没 entitlement 的开发构建就是这样）就原地不动，
    /// 老条目照旧留着，调用方拿到的令牌不受影响。
    private func migrate(token: String, serverID: String, foundAt index: Int) {
        guard let outcome = try? write(accessToken: token, serverID: serverID),
              outcome.index < index else {
            return
        }
        clearLocations(worseThan: outcome.index, serverID: serverID)
    }

    // MARK: -

    private func query(for location: PendingNetKeychainLocation, serverID: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID,
            kSecAttrSynchronizable: location.synchronizable,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = location.dataProtection
        #endif
        if let group = location.accessGroup {
            query[kSecAttrAccessGroup] = group
        }
        return query
    }
}

public enum PendingNetCredentialStore {
    /// 钥匙串条目的 `kSecAttrService`，**不是 bundle id**。名字长得像纯属历史。
    ///
    /// 2026-08-08 把 macOS 的 bundle id 归一到 `com.pendingname.pendingnet` 时，
    /// 这一个字符串是**故意**留在旧名字上的：service 是查询条件的一部分，改掉
    /// 就等于所有老用户已经存下的设备令牌再也匹配不到（下面那条候选链只覆盖
    /// accessGroup 和同步位，不覆盖 service 改名）。要动它得先写一次读旧名、
    /// 写新名的搬迁，在那之前一个字都别改。
    public static let service = "net.pending.PendingNet.server-token"

    /// 两端共用的 keychain access group。entitlements 里写的是
    /// `$(AppIdentifierPrefix)com.pendingname.pendingnet`，展开后就是这个值。
    /// 两端的 bundle id 现在都是 `com.pendingname.pendingnet`，但仍然靠这个显式
    /// 共享组读同一批条目 —— 共享组的名字和 bundle id 是两回事，不该互相跟着变。
    public static let sharedAccessGroup = "M42BKJN82S.com.pendingname.pendingnet"

    /// 从好到差：iCloud 同步 + 共享组 → iCloud 同步 + App 默认组 → 老的本地条目。
    /// 最后一项就是 0.3.18 及以前写进去的形状，老用户升级后照样读得到。
    public static let locations: [PendingNetKeychainLocation] = [
        .init(dataProtection: true, synchronizable: true, accessGroup: sharedAccessGroup),
        .init(dataProtection: true, synchronizable: true, accessGroup: nil),
        .init(dataProtection: false, synchronizable: false, accessGroup: nil),
    ]

    private static let core = PendingNetCredentialStoreCore(
        service: service,
        locations: locations,
        backend: SecItemKeychainBackend()
    )

    public static func save(accessToken: String, serverID: String) throws {
        try core.save(accessToken: accessToken, serverID: serverID)
    }

    public static func load(serverID: String) throws -> String? {
        try core.load(serverID: serverID)
    }

    private static let log = Logger(
        subsystem: "com.pendingname.pendingnet",
        category: "credential-store"
    )

    /// 启动时跑一遍：把还躺在老位置上的令牌搬到能经 iCloud 同步的位置，
    /// 并回报每一台的处境（界面拿它标出「本机未配对」的那几行）。
    ///
    /// **搬不动要能看见。** 以前迁移是 `try?` 悄悄吞掉的：写不进同步位就原地
    /// 不动，谁也不知道，用户只看到另一台设备上的 VPS 全是死的却查不出原因。
    /// 现在每一条非正常结果都落一行日志（`log stream --predicate
    /// 'subsystem == "com.pendingname.pendingnet"'` 看得到），本机没有令牌的那
    /// 几台还会由界面直接标出来。
    @discardableResult
    public static func promoteAll(serverIDs: [String]) -> [String: PendingNetCredentialPromotion] {
        var results: [String: PendingNetCredentialPromotion] = [:]
        for serverID in serverIDs {
            let outcome = core.promote(serverID: serverID)
            results[serverID] = outcome
            switch outcome {
            case .synchronizable:
                break
            case .notStored:
                log.notice("\(serverID, privacy: .public)：本机没有这一台的访问凭据，需要重新导入链接")
            case .localOnly(let status):
                log.error("""
                    \(serverID, privacy: .public)：访问凭据只能留在本机，搬不上 iCloud 钥匙串\
                    （Keychain \(status.map(String.init) ?? "无错误码", privacy: .public)）——\
                    这台设备用得了，别的设备看不到
                    """)
            case .unreadable(let status):
                log.error("""
                    \(serverID, privacy: .public)：钥匙串读不了，说不准有没有凭据\
                    （Keychain \(status.map(String.init) ?? "无错误码", privacy: .public)）
                    """)
            }
        }
        return results
    }
}
