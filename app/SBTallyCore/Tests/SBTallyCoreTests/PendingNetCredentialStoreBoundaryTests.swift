import Foundation
import Security
import XCTest
@testable import SBTallyCore

/// 钥匙串候选链的边界。与 `PendingNetCredentialStoreTests` 分开放：那边盯的是
/// 主干（写进最好的位置、老条目读得到并被搬上去），这边盯的是**降级路径**——
/// 哪一档写不进、读的时候撞上硬错误、迁移写失败，各自该怎么表现。
///
/// 这些路径在真机上极难触发（要么有 entitlement 要么没有，不会中途变），
/// 但一旦踩中，代价是用户的配对丢了或者被平白要求重新配对，只能靠单测钉死。

/// 内存版钥匙串。真钥匙串在未签名的测试二进制里碰不得（数据保护钥匙串直接
/// 回 -34018），降级逻辑只能这样才测得到。
///
/// 比主干测试那份多一件事：**读与写可以分别拒绝**。「读得到但写不进去」是真
/// 存在的形态（钥匙串锁着、条目的 accessible 属性不允许当前状态写入），而
/// 迁移失败这条路径只有在这种形态下才走得到。
private final class MemoryKeychain: PendingNetKeychainBackend, @unchecked Sendable {
    struct Slot: Hashable {
        var service: String
        var account: String
        var synchronizable: Bool
        var accessGroup: String?
        var dataProtection: Bool
    }

    var items: [Slot: Data] = [:]
    /// 命中的位置读写一律回 `errSecMissingEntitlement`——「这台设备上这一档
    /// 根本用不了」。
    var refused: (Slot) -> Bool = { _ in false }
    /// 只拒绝写入，读照旧。
    var refusedForWriting: (Slot) -> Bool = { _ in false }
    private(set) var deleted: [Slot] = []

    private func slot(from query: [CFString: Any]) -> Slot {
        Slot(
            service: query[kSecAttrService] as? String ?? "",
            account: query[kSecAttrAccount] as? String ?? "",
            synchronizable: query[kSecAttrSynchronizable] as? Bool ?? false,
            accessGroup: query[kSecAttrAccessGroup] as? String,
            // macOS 上才会带这一位；iOS 上恒为数据保护钥匙串。
            dataProtection: query[kSecUseDataProtectionKeychain] as? Bool ?? true
        )
    }

    private func writable(_ slot: Slot) -> Bool { !refused(slot) && !refusedForWriting(slot) }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, data: Data?) {
        let slot = slot(from: query)
        if refused(slot) { return (errSecMissingEntitlement, nil) }
        guard let data = items[slot] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        let slot = slot(from: attributes)
        guard writable(slot) else { return errSecMissingEntitlement }
        items[slot] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        let slot = slot(from: query)
        guard writable(slot) else { return errSecMissingEntitlement }
        guard items[slot] != nil else { return errSecItemNotFound }
        items[slot] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        let slot = slot(from: query)
        guard writable(slot) else { return errSecMissingEntitlement }
        deleted.append(slot)
        guard items.removeValue(forKey: slot) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

final class PendingNetCredentialStoreBoundaryTests: XCTestCase {
    private let service = PendingNetCredentialStore.service
    private let shared = PendingNetCredentialStore.sharedAccessGroup

    #if os(macOS)
    private let legacyUsesDataProtection = false
    #else
    private let legacyUsesDataProtection = true
    #endif

    private func makeCore(_ backend: MemoryKeychain) -> PendingNetCredentialStoreCore {
        PendingNetCredentialStoreCore(
            service: service,
            locations: PendingNetCredentialStore.locations,
            backend: backend
        )
    }

    /// 最好的位置：iCloud 同步 + 共享组。
    private func bestSlot(_ serverID: String) -> MemoryKeychain.Slot {
        .init(
            service: service, account: serverID,
            synchronizable: true, accessGroup: shared, dataProtection: true
        )
    }

    /// 次好的位置：iCloud 同步 + App 默认组。
    private func middleSlot(_ serverID: String) -> MemoryKeychain.Slot {
        .init(
            service: service, account: serverID,
            synchronizable: true, accessGroup: nil, dataProtection: true
        )
    }

    /// 最差的位置：0.3.18 及以前写进去的形状，纯本地、不同步、无共享组。
    private func legacySlot(_ serverID: String) -> MemoryKeychain.Slot {
        .init(
            service: service, account: serverID,
            synchronizable: false, accessGroup: nil, dataProtection: legacyUsesDataProtection
        )
    }

    // MARK: - 读：撞上硬错误 ≠ 没有令牌

    /// 更好的位置回的是硬错误（不是「没有这一条」）时，读必须继续往下找，
    /// 而不是当场失败。没有 entitlement 的构建就是这样：同步条目一律回
    /// `errSecMissingEntitlement`，可老条目明明还在。
    func testLoadKeepsLookingPastALocationThatFailsHard() throws {
        let backend = MemoryKeychain()
        backend.items[legacySlot("vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 钥匙串整个用不了、且哪儿都没有令牌时必须**抛错**，不能返回 nil。
    ///
    /// 这条差别有用户可见的后果：调用方（iOS 的 `start`）把 nil 当成「这台设备
    /// 没配对过」，会直接要求用户重新配对；而钥匙串坏掉时该做的是报错——
    /// 用户的配对其实还在，重配一次反而白丢一次。
    func testBrokenKeychainThrowsInsteadOfLookingLikeNoCredential() {
        let backend = MemoryKeychain()
        backend.refused = { _ in true }

        XCTAssertThrowsError(try makeCore(backend).load(serverID: "vps1")) { error in
            XCTAssertEqual(error as? PendingNetPairingError, .keychain(errSecMissingEntitlement))
        }
    }

    /// 对照组：钥匙串好好的、只是真没有这一条，才返回 nil。
    func testHealthyKeychainWithNoEntryReturnsNil() throws {
        XCTAssertNil(try makeCore(MemoryKeychain()).load(serverID: "vps1"))
    }

    /// 令牌已经在最好的位置上时，读不该顺手删任何东西——迁移只在「找到的位置
    /// 比能写的最好位置差」时才发生。
    func testLoadFromTheBestLocationTouchesNothing() throws {
        let backend = MemoryKeychain()
        backend.items[bestSlot("vps1")] = Data("token-1".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "token-1")

        XCTAssertTrue(backend.deleted.isEmpty)
        XCTAssertEqual(backend.items.count, 1)
    }

    // MARK: - 迁移：搬到「实际能用的最好位置」，不是理论上最好的那个

    /// 共享组用不了、但同步条目能写：老条目要搬到**次好**那一档，而不是因为
    /// 最好那档写不进就干脆不搬。
    func testMigrationLandsInTheBestLocationThatActuallyWorks() throws {
        let backend = MemoryKeychain()
        backend.items[legacySlot("vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.accessGroup != nil }

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[middleSlot("vps1")], Data("legacy-token".utf8))
        XCTAssertNil(backend.items[legacySlot("vps1")], "搬上去之后老条目要清掉，否则下次可能读回旧值")
        XCTAssertNil(backend.items[bestSlot("vps1")])
    }

    /// 迁移写不进去时必须原地放弃：老条目留着、令牌照常返回、不抛错。
    ///
    /// 这里的形态是「读得到但写不动」（钥匙串锁着就是这样），跟「这一档根本
    /// 用不了」不是一回事——只有这种形态才真正走到 `migrate` 里那条
    /// 「写失败就什么都别动」的分支。
    func testFailedMigrationLeavesTheOldEntryExactlyWhereItWas() throws {
        let backend = MemoryKeychain()
        backend.items[legacySlot("vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }   // 上面两档读不到
        backend.refusedForWriting = { _ in true } // 哪一档都写不进去

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[legacySlot("vps1")], Data("legacy-token".utf8))
        XCTAssertTrue(backend.deleted.isEmpty, "迁移没成功就一个都不许删")
    }

    /// 只有最差那一档能写时：`save` 落在老位置，`load` 读得回来，而且全程
    /// 一个都不删——能写的最好位置就是它自己，没有可搬的去处。多删一次的
    /// 后果是把用户唯一那份令牌删掉。
    func testOnlyTheWorstLocationWritableStillSavesAndLoadsWithoutDeleting() throws {
        let backend = MemoryKeychain()
        backend.refused = { $0.synchronizable }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")
        XCTAssertEqual(backend.items[legacySlot("vps1")], Data("token-1".utf8))

        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
        XCTAssertTrue(backend.deleted.isEmpty, "唯一那份令牌不能在读的时候被删掉")
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    // MARK: - 清理只针对更差的位置、且只针对这一台 VPS

    /// 写进最好的位置之后只清更差的那几档；刚写进去的那份不能被自己的清理
    /// 顺手删掉。
    func testSaveClearsWorseLocationsOnlyAndKeepsWhatItJustWrote() throws {
        let backend = MemoryKeychain()
        backend.items[middleSlot("vps1")] = Data("stale-middle".utf8)
        backend.items[legacySlot("vps1")] = Data("stale-legacy".utf8)

        try makeCore(backend).save(accessToken: "fresh", serverID: "vps1")

        XCTAssertEqual(backend.items[bestSlot("vps1")], Data("fresh".utf8))
        XCTAssertNil(backend.items[middleSlot("vps1")])
        XCTAssertNil(backend.items[legacySlot("vps1")])
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "fresh")
    }

    /// 清理按 VPS 分账：给 A 存令牌不能把 B 的老条目一起清掉。多台 VPS 是
    /// 已经上线的功能，踩中的现象是「换一台 VPS 之后另一台要求重新配对」。
    func testSavingOneServerNeverTouchesAnotherServersEntries() throws {
        let backend = MemoryKeychain()
        backend.items[legacySlot("vps2")] = Data("vps2-legacy".utf8)

        try makeCore(backend).save(accessToken: "vps1-token", serverID: "vps1")

        XCTAssertEqual(backend.items[legacySlot("vps2")], Data("vps2-legacy".utf8))
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "vps1-token")
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps2"), "vps2-legacy")
    }
}
