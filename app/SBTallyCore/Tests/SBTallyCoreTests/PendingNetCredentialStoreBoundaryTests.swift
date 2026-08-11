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

/// 内存版钥匙串见 `FakeKeychain.swift`——主干测试与这里共用同一份，access
/// group 通配那条规矩必须两边一致，否则一边测得出的 bug 另一边测不出。它同时
/// 支持「整档用不了」(`refused`) 和「读得到但写不动」(`refusedForWriting`) 两种
/// 形态，后者是迁移失败那条分支唯一走得到的路。
final class PendingNetCredentialStoreBoundaryTests: XCTestCase {
    private let service = PendingNetCredentialStore.service
    private let shared = PendingNetCredentialStore.sharedAccessGroup

    private let locations = PendingNetCredentialStore.locations

    /// 没有共享组 entitlement 的构建（本地 ad-hoc 签名就是这样）里，App 自己
    /// 那个默认组。它和共享组互不相通——这正是「退到次好那一档」的含义。
    private let appPrivateGroup = "M42BKJN82S.com.pendingname.pendingnet.private"

    private func makeCore(_ backend: FakeKeychain) -> PendingNetCredentialStoreCore {
        PendingNetCredentialStoreCore(service: service, locations: locations, backend: backend)
    }

    /// 有共享组 entitlement 的构建：默认组**就是**共享组，于是最好和次好那两档
    /// 落在同一个槽位上（entitlements 里只有共享组这一个，它同时是 App 的默认组）。
    private func entitled() -> FakeKeychain { FakeKeychain() }

    /// 没有共享组 entitlement 的构建：显式指定组的读写一律被拒，不带组的读写
    /// 落在 App 自己那个组。这时三档才真的是三个不同的槽位。
    private func unentitled() -> FakeKeychain {
        let backend = FakeKeychain()
        backend.defaultAccessGroup = appPrivateGroup
        backend.refused = { $0.accessGroup != nil }
        return backend
    }

    /// 最好的位置：iCloud 同步 + 共享组。
    private func bestSlot(_ backend: FakeKeychain, _ serverID: String) -> FakeKeychain.Slot {
        backend.slot(locations[0], service: service, serverID: serverID)
    }

    /// 次好的位置：iCloud 同步 + App 默认组。
    private func middleSlot(_ backend: FakeKeychain, _ serverID: String) -> FakeKeychain.Slot {
        backend.slot(locations[1], service: service, serverID: serverID)
    }

    /// 最差的位置：0.3.18 及以前写进去的形状，纯本地、不同步、无共享组。
    private func legacySlot(_ backend: FakeKeychain, _ serverID: String) -> FakeKeychain.Slot {
        backend.slot(locations[2], service: service, serverID: serverID)
    }

    // MARK: - 读：撞上硬错误 ≠ 没有令牌

    /// 更好的位置回的是硬错误（不是「没有这一条」）时，读必须继续往下找，
    /// 而不是当场失败。没有 entitlement 的构建就是这样：同步条目一律回
    /// `errSecMissingEntitlement`，可老条目明明还在。
    func testLoadKeepsLookingPastALocationThatFailsHard() throws {
        let backend = FakeKeychain()
        backend.items[legacySlot(backend, "vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 钥匙串整个用不了、且哪儿都没有令牌时必须**抛错**，不能返回 nil。
    ///
    /// 这条差别有用户可见的后果：调用方（iOS 的 `start`）把 nil 当成「这台设备
    /// 没配对过」，会直接要求用户重新配对；而钥匙串坏掉时该做的是报错——
    /// 用户的配对其实还在，重配一次反而白丢一次。
    func testBrokenKeychainThrowsInsteadOfLookingLikeNoCredential() {
        let backend = FakeKeychain()
        backend.refused = { _ in true }

        XCTAssertThrowsError(try makeCore(backend).load(serverID: "vps1")) { error in
            XCTAssertEqual(error as? PendingNetPairingError, .keychain(errSecMissingEntitlement))
        }
    }

    /// 对照组：钥匙串好好的、只是真没有这一条，才返回 nil。
    func testHealthyKeychainWithNoEntryReturnsNil() throws {
        XCTAssertNil(try makeCore(FakeKeychain()).load(serverID: "vps1"))
    }

    /// 无 entitlement 的开发构建读同步位置会回 -34018；只要后面的本地位置
    /// 可访问且明确说没有条目，最终结论就仍是「没找到」，不能拿前面的权限
    /// 错误覆盖它，让用户看到一条与重新导入 .pdn 无关的误导信息。
    func testMissingEntitlementBeforeAccessibleNotFoundStillReturnsNil() throws {
        let backend = FakeKeychain()
        backend.refused = { $0.synchronizable }

        XCTAssertNil(try makeCore(backend).load(serverID: "vps1"))
    }

    /// 令牌已经在最好的位置上时，读不该顺手删任何东西——迁移只在「找到的位置
    /// 比能写的最好位置差」时才发生。
    func testLoadFromTheBestLocationTouchesNothing() throws {
        let backend = FakeKeychain()
        backend.items[bestSlot(backend, "vps1")] = Data("token-1".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "token-1")

        XCTAssertTrue(backend.deleted.isEmpty)
        XCTAssertEqual(backend.items.count, 1)
    }

    // MARK: - 迁移：搬到「实际能用的最好位置」，不是理论上最好的那个

    /// 共享组用不了、但同步条目能写：老条目要搬到**次好**那一档，而不是因为
    /// 最好那档写不进就干脆不搬。
    func testMigrationLandsInTheBestLocationThatActuallyWorks() throws {
        let backend = unentitled()
        backend.items[legacySlot(backend, "vps1")] = Data("legacy-token".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[middleSlot(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertNil(backend.items[legacySlot(backend, "vps1")], "搬上去之后老条目要清掉，否则下次可能读回旧值")
        XCTAssertNil(backend.items[bestSlot(backend, "vps1")])
    }

    /// 迁移写不进去时必须原地放弃：老条目留着、令牌照常返回、不抛错。
    ///
    /// 这里的形态是「读得到但写不动」（钥匙串锁着就是这样），跟「这一档根本
    /// 用不了」不是一回事——只有这种形态才真正走到 `migrate` 里那条
    /// 「写失败就什么都别动」的分支。
    func testFailedMigrationLeavesTheOldEntryExactlyWhereItWas() throws {
        let backend = FakeKeychain()
        backend.items[legacySlot(backend, "vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }   // 上面两档读不到
        backend.refusedForWriting = { _ in true } // 哪一档都写不进去

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[legacySlot(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertTrue(backend.deleted.isEmpty, "迁移没成功就一个都不许删")
    }

    /// 只有最差那一档能写时：`save` 落在老位置，`load` 读得回来，而且全程
    /// 一个都不删——能写的最好位置就是它自己，没有可搬的去处。多删一次的
    /// 后果是把用户唯一那份令牌删掉。
    func testOnlyTheWorstLocationWritableStillSavesAndLoadsWithoutDeleting() throws {
        let backend = FakeKeychain()
        backend.refused = { $0.synchronizable }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")
        XCTAssertEqual(backend.items[legacySlot(backend, "vps1")], Data("token-1".utf8))

        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
        XCTAssertTrue(backend.deleted.isEmpty, "唯一那份令牌不能在读的时候被删掉")
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    // MARK: - 清理只针对更差的位置、且只针对这一台 VPS

    /// 写进最好的位置之后清掉更差那几档的残留；**刚写进去的那份不能被自己的
    /// 清理顺手删掉**。
    ///
    /// 后半句是 0.3.21 真踩过的坑：「同步 + App 默认组」那一档的删除查询不带
    /// access group，而不带组在真钥匙串里是**通配**——它把刚写进共享组的那条
    /// 一并删了。于是 `save` 报成功、事后一条不剩，令牌再也搬不上能同步的位置。
    func testSaveClearsWorseLocationsOnlyAndKeepsWhatItJustWrote() throws {
        let backend = entitled()
        backend.items[legacySlot(backend, "vps1")] = Data("stale-legacy".utf8)

        try makeCore(backend).save(accessToken: "fresh", serverID: "vps1")

        XCTAssertEqual(backend.items[bestSlot(backend, "vps1")], Data("fresh".utf8))
        XCTAssertNil(backend.items[legacySlot(backend, "vps1")])
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "fresh")
    }

    /// 有共享组 entitlement 时，「同步 + 共享组」和「同步 + App 默认组」本来就是
    /// **同一个槽位**——entitlements 里只有共享组这一个，它同时就是 App 的默认组。
    /// 候选链把它们列成两档只是为了兜住没有 entitlement 的构建；清理时必须认得
    /// 出这一点，不能把次好那档当成一个可以放心清空的独立抽屉。
    func testTheSharedGroupIsAlsoTheDefaultGroupOnAnEntitledBuild() throws {
        let backend = entitled()

        try makeCore(backend).save(accessToken: "token-1", serverID: "vps1")

        XCTAssertEqual(bestSlot(backend, "vps1"), middleSlot(backend, "vps1"))
        XCTAssertEqual(backend.items.count, 1)
    }

    /// 清理按 VPS 分账：给 A 存令牌不能把 B 的老条目一起清掉。多台 VPS 是
    /// 已经上线的功能，踩中的现象是「换一台 VPS 之后另一台要求重新配对」。
    func testSavingOneServerNeverTouchesAnotherServersEntries() throws {
        let backend = FakeKeychain()
        backend.items[legacySlot(backend, "vps2")] = Data("vps2-legacy".utf8)

        try makeCore(backend).save(accessToken: "vps1-token", serverID: "vps1")

        XCTAssertEqual(backend.items[legacySlot(backend, "vps2")], Data("vps2-legacy".utf8))
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "vps1-token")
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps2"), "vps2-legacy")
    }
}
