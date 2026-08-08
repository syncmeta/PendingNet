import Foundation
import Security

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
        guard let best = try write(accessToken: accessToken, serverID: serverID) else {
            return
        }
        // 写进了更好的位置，把更差位置上的旧条目清掉，免得读的时候被旧值挡住。
        for location in locations.dropFirst(best + 1) {
            _ = backend.delete(query(for: location, serverID: serverID))
        }
    }

    /// 返回写成功的位置在 `locations` 里的下标；全都写不进去就抛错。
    private func write(accessToken: String, serverID: String) throws -> Int? {
        let tokenData = Data(accessToken.utf8)
        var lastStatus: OSStatus = errSecSuccess
        for (index, location) in locations.enumerated() {
            let status = write(tokenData, serverID: serverID, to: location)
            if status == errSecSuccess { return index }
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
        var lastFailure: OSStatus?
        for (index, location) in locations.enumerated() {
            var find = query(for: location, serverID: serverID)
            find[kSecReturnData] = true
            find[kSecMatchLimit] = kSecMatchLimitOne
            let (status, data) = backend.copyMatching(find)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess,
                  let data,
                  let token = String(data: data, encoding: .utf8) else {
                lastFailure = status
                continue
            }
            if index > 0 { migrate(token: token, serverID: serverID, foundAt: index) }
            return token
        }
        if let lastFailure { throw PendingNetPairingError.keychain(lastFailure) }
        return nil
    }

    /// 把在 `foundAt` 找到的老条目搬到当前能用的最好位置。
    ///
    /// 无损是硬要求：写不进去（没 entitlement 的开发构建就是这样）就原地不动，
    /// 老条目照旧留着，调用方拿到的令牌不受影响。
    private func migrate(token: String, serverID: String, foundAt index: Int) {
        guard let best = try? write(accessToken: token, serverID: serverID), best < index else {
            return
        }
        for location in locations[(best + 1)...] {
            _ = backend.delete(query(for: location, serverID: serverID))
        }
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
    public static let service = "net.pending.PendingNet.server-token"

    /// 两端共用的 keychain access group。entitlements 里写的是
    /// `$(AppIdentifierPrefix)com.pendingname.pendingnet`，展开后就是这个值。
    /// macOS 与 iOS 的 bundle id 不同（net.pending.PendingNet / com.pendingname.pendingnet），
    /// 靠这个显式共享组才能读到同一批条目。
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
}
