import Foundation
import Security
@testable import SBTallyCore

/// 内存版钥匙串，`PendingNetCredentialStoreCore` 的候选链与迁移逻辑全靠它才测
/// 得到——真钥匙串在未签名的测试二进制里碰不得（数据保护钥匙串直接回 -34018）。
///
/// ## access group 是**通配**，不是一个值
///
/// 这是这份假实现最要紧的一条规矩：不带 `kSecAttrAccessGroup` 的查询会横扫
/// 这个 App 有权访问的**所有**组，不带组的写入则落在默认组（entitlement 里的
/// 第一个组）。
///
/// 早先那版假实现把「不带组」当成一个独立的抽屉，于是「写进共享组、再按默认
/// 组去清理更差的位置」在测试里看着人畜无害，真机上却是**自己把刚写进去的令牌
/// 删掉**——保存报成功，事后一条不剩。0.3.21 就是这么把两台 VPS 的令牌卡在老
/// 位置、同步不过去的。假实现不照着真钥匙串的规矩来，这一类 bug 就永远测不出来。
///
/// file-based 钥匙串（macOS 上 `dataProtection == false`）没有组的概念，条目的
/// 组恒为 nil。
final class FakeKeychain: PendingNetKeychainBackend, @unchecked Sendable {
    /// 查询/写入里**写明**的位置。`accessGroup == nil` = 这一次没写组。
    struct Key: Hashable {
        var service: String
        var account: String
        var synchronizable: Bool
        var accessGroup: String?
        var dataProtection: Bool
    }

    /// 条目**实际落在**哪儿。数据保护钥匙串里一定属于某个具体的组。
    struct Slot: Hashable {
        var service: String
        var account: String
        var synchronizable: Bool
        var dataProtection: Bool
        var accessGroup: String?
    }

    /// 不带组的写入落在这里。有共享组 entitlement 的构建，默认组**就是**共享组
    /// （两端的 keychain-access-groups 里只有它一个）；没有 entitlement 的
    /// ad-hoc 构建则是 App 自己那个组，与共享组互不相通。
    var defaultAccessGroup = PendingNetCredentialStore.sharedAccessGroup

    var items: [Slot: Data] = [:]
    /// 命中的位置读写一律回 `errSecMissingEntitlement`——「这台设备上这一档
    /// 根本用不了」。谓词收到的是**查询写明的样子**，组没写就是 nil。
    var refused: (Key) -> Bool = { _ in false }
    /// 只拒绝写入，读照旧。「读得到但写不动」是真存在的形态（钥匙串锁着），
    /// 迁移失败那条路径只有在这种形态下才走得到。
    var refusedForWriting: (Key) -> Bool = { _ in false }
    private(set) var deleted: [Key] = []

    /// 某个候选位置上的条目**实际**落在哪个槽位。测试拿它断言「东西在哪」，
    /// 免得每处手抄一遍 dataProtection / 默认组的换算规则。
    func slot(_ location: PendingNetKeychainLocation, service: String, serverID: String) -> Slot {
        // 查询构造只在 macOS 上带 kSecUseDataProtectionKeychain；iOS 上恒为
        // 数据保护钥匙串，这里要跟着一样，否则断言查的是个不存在的槽位。
        #if os(macOS)
        let dataProtection = location.dataProtection
        #else
        let dataProtection = true
        #endif
        return slot(writing: Key(
            service: service,
            account: serverID,
            synchronizable: location.synchronizable,
            accessGroup: location.accessGroup,
            dataProtection: dataProtection
        ))
    }

    private func key(from query: [CFString: Any]) -> Key {
        Key(
            service: query[kSecAttrService] as? String ?? "",
            account: query[kSecAttrAccount] as? String ?? "",
            synchronizable: query[kSecAttrSynchronizable] as? Bool ?? false,
            accessGroup: query[kSecAttrAccessGroup] as? String,
            // macOS 上才会带这一位；iOS 上恒为数据保护钥匙串。
            dataProtection: query[kSecUseDataProtectionKeychain] as? Bool ?? true
        )
    }

    /// 写入落在哪个具体的槽位。
    private func slot(writing key: Key) -> Slot {
        Slot(
            service: key.service,
            account: key.account,
            synchronizable: key.synchronizable,
            dataProtection: key.dataProtection,
            accessGroup: key.dataProtection ? (key.accessGroup ?? defaultAccessGroup) : nil
        )
    }

    /// 这次查询命中哪些槽位。组没写明就是通配，横扫所有组。
    private func slots(matching key: Key) -> [Slot] {
        items.keys.filter { slot in
            guard slot.service == key.service,
                  slot.account == key.account,
                  slot.synchronizable == key.synchronizable,
                  slot.dataProtection == key.dataProtection
            else { return false }
            guard let wanted = key.accessGroup, slot.dataProtection else { return true }
            return slot.accessGroup == wanted
        }
        // 命中多条时给个稳定的顺序，免得测试看运气。
        .sorted { ($0.accessGroup ?? "") < ($1.accessGroup ?? "") }
    }

    private func writable(_ key: Key) -> Bool { !refused(key) && !refusedForWriting(key) }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, data: Data?) {
        let key = key(from: query)
        if refused(key) { return (errSecMissingEntitlement, nil) }
        guard let slot = slots(matching: key).first, let data = items[slot] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        let key = key(from: attributes)
        guard writable(key) else { return errSecMissingEntitlement }
        let slot = slot(writing: key)
        guard items[slot] == nil else { return errSecDuplicateItem }
        items[slot] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        let key = key(from: query)
        guard writable(key) else { return errSecMissingEntitlement }
        let matched = slots(matching: key)
        guard !matched.isEmpty else { return errSecItemNotFound }
        for slot in matched { items[slot] = attributes[kSecValueData] as? Data }
        return errSecSuccess
    }

    /// 真钥匙串的 `SecItemDelete` 会删掉**所有**命中的条目——组没写明时这就是
    /// 「把这个 App 所有组里的同名条目一起删掉」。
    func delete(_ query: [CFString: Any]) -> OSStatus {
        let key = key(from: query)
        guard writable(key) else { return errSecMissingEntitlement }
        deleted.append(key)
        let matched = slots(matching: key)
        guard !matched.isEmpty else { return errSecItemNotFound }
        for slot in matched { items.removeValue(forKey: slot) }
        return errSecSuccess
    }
}
