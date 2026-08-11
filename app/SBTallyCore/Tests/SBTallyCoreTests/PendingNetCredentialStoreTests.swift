import Foundation
import Security
import XCTest
@testable import SBTallyCore

/// 内存版钥匙串是共用的（见 `FakeKeychain.swift`）——access group 通配那条规矩
/// 必须两边一致，否则一边测得出的 bug 另一边测不出。
final class PendingNetCredentialStoreTests: XCTestCase {
    private let service = PendingNetCredentialStore.service
    private let shared = PendingNetCredentialStore.sharedAccessGroup
    private let locations = PendingNetCredentialStore.locations

    private func makeCore(_ backend: FakeKeychain) -> PendingNetCredentialStoreCore {
        PendingNetCredentialStoreCore(service: service, locations: locations, backend: backend)
    }

    /// 最好的位置：iCloud 同步 + 共享组。
    private func syncedKey(_ backend: FakeKeychain, _ serverID: String) -> FakeKeychain.Slot {
        backend.slot(locations[0], service: service, serverID: serverID)
    }

    /// 0.3.18 及以前写进去的形状：普通 file-based 钥匙串、不同步、无共享组。
    private func legacyKey(_ backend: FakeKeychain, _ serverID: String) -> FakeKeychain.Slot {
        backend.slot(locations[2], service: service, serverID: serverID)
    }

    func testSaveLandsInTheSynchronizableSharedGroup() throws {
        let backend = FakeKeychain()
        try makeCore(backend).save(accessToken: "token-1", serverID: "vps1")
        XCTAssertEqual(backend.items[syncedKey(backend, "vps1")], Data("token-1".utf8))
    }

    func testSaveOverwritesExistingToken() throws {
        let backend = FakeKeychain()
        let core = makeCore(backend)
        try core.save(accessToken: "old", serverID: "vps1")
        try core.save(accessToken: "new", serverID: "vps1")
        XCTAssertEqual(try core.load(serverID: "vps1"), "new")
        XCTAssertEqual(backend.items.count, 1)
    }

    func testLoadReturnsNilWhenNothingStored() throws {
        XCTAssertNil(try makeCore(FakeKeychain()).load(serverID: "vps1"))
    }

    // MARK: - 迁移（老用户升级后现有配对不能丢）

    func testLegacyTokenIsStillReadableAfterUpgrade() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    func testLegacyTokenIsMigratedToTheSynchronizableItem() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        // 搬上去了，而且老条目清掉了（否则下次读可能读回旧值）。
        XCTAssertEqual(backend.items[syncedKey(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertNil(backend.items[legacyKey(backend, "vps1")])
        // 搬完再读一次拿到的还是同一个令牌。
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 没有 entitlement 的构建（本地 ad-hoc 签名就是这样）：同步条目写不进去，
    /// 迁移必须原地放弃——老条目留着，令牌照常读得到，不抛错。
    func testMigrationIsLosslessWhenICloudKeychainIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[legacyKey(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    /// 同上，写新令牌时也要能退回老位置，不能因为没 entitlement 就配对失败。
    func testSaveFallsBackToTheLocalItemWhenICloudKeychainIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.refused = { $0.synchronizable }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")

        XCTAssertEqual(backend.items[legacyKey(backend, "vps1")], Data("token-1".utf8))
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    /// 只有共享组不可用（entitlement 没配全）时退到 App 默认组，仍然是同步条目。
    ///
    /// 这种构建的默认组**不是**共享组——它压根没有共享组的 entitlement，写进去
    /// 的东西也就不会和别的设备互通。
    func testFallsBackToTheDefaultAccessGroupWhenTheSharedGroupIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.defaultAccessGroup = "M42BKJN82S.com.pendingname.pendingnet.private"
        backend.refused = { $0.accessGroup != nil }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")

        XCTAssertEqual(
            backend.items[backend.slot(locations[1], service: service, serverID: "vps1")],
            Data("token-1".utf8)
        )
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    /// **回归测试（0.3.21 的真 bug）**：写进共享组之后，清理更差位置时那条
    /// 「同步 + App 默认组」的删除查询没带 access group ——不带组等于通配，
    /// 它会把刚写进共享组的那条一并删掉。现象是 `save` 报成功、事后一条不剩，
    /// 令牌永远搬不上能同步的位置，另一台设备上的 VPS 全是死的。
    func testSaveKeepsWhatItJustWroteWhenCleaningUpWorseLocations() throws {
        let backend = FakeKeychain()
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")

        XCTAssertEqual(
            backend.items[syncedKey(backend, "vps1")],
            Data("token-1".utf8),
            "清理更差的位置不能把刚写进共享组的那条删掉"
        )
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    /// 同一条自删路径在**迁移**里也有一份：老条目搬上去之后紧接着被清理删掉，
    /// 结果是三个位置一个都不剩——用户唯一那份令牌就这么没了。
    func testMigrationKeepsTheTokenItJustPromoted() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(
            backend.items[syncedKey(backend, "vps1")],
            Data("legacy-token".utf8),
            "搬上去的那条不能被自己的清理删掉"
        )
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 同步条目优先于老条目：两份都在时读到的是新的那份。
    func testSynchronizableItemWinsOverALeftoverLegacyItem() throws {
        let backend = FakeKeychain()
        backend.items[syncedKey(backend, "vps1")] = Data("new".utf8)
        backend.items[legacyKey(backend, "vps1")] = Data("stale".utf8)
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "new")
    }

    func testSaveClearsLeftoverLegacyItem() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("stale".utf8)
        try makeCore(backend).save(accessToken: "new", serverID: "vps1")
        XCTAssertNil(backend.items[legacyKey(backend, "vps1")])
        XCTAssertEqual(backend.items[syncedKey(backend, "vps1")], Data("new".utf8))
    }

    // MARK: - 主动搬迁（启动时跑，不等用户先去点某台 VPS）

    /// 躺在老位置上的令牌，不用等谁去读就该被搬到能同步的位置上。
    func testPromoteMovesALegacyTokenOntoTheSynchronizableLocation() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)

        XCTAssertEqual(makeCore(backend).promote(serverID: "vps1"), .synchronizable)

        XCTAssertEqual(backend.items[syncedKey(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertNil(backend.items[legacyKey(backend, "vps1")])
    }

    /// 已经在能同步的位置上：什么都不用做，也不许动任何条目。
    func testPromoteLeavesAnAlreadySynchronizableTokenAlone() throws {
        let backend = FakeKeychain()
        backend.items[syncedKey(backend, "vps1")] = Data("token-1".utf8)

        XCTAssertEqual(makeCore(backend).promote(serverID: "vps1"), .synchronizable)

        XCTAssertTrue(backend.deleted.isEmpty)
        XCTAssertEqual(backend.items[syncedKey(backend, "vps1")], Data("token-1".utf8))
    }

    /// 这台设备压根没有这一条——iCloud 把 VPS 记录同步过来了，令牌没跟过来，
    /// 主人手机上那两台就是这个状态。界面要靠它把行标成「本机未配对」。
    func testPromoteReportsAMissingCredential() {
        XCTAssertEqual(makeCore(FakeKeychain()).promote(serverID: "vps1"), .notStored)
    }

    /// 搬不上去时必须**说出来**，而且原地不动：老条目留着，令牌照常读得到。
    /// 以前这条路径是 `try?` 悄悄吞掉的。
    func testPromoteReportsWhenTheTokenCannotLeaveThisDevice() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey(backend, "vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }

        XCTAssertEqual(
            makeCore(backend).promote(serverID: "vps1"),
            .localOnly(errSecMissingEntitlement)
        )

        XCTAssertEqual(backend.items[legacyKey(backend, "vps1")], Data("legacy-token".utf8))
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 钥匙串整个读不了 ≠ 没有令牌。报成 `notStored` 会让界面把一台好好的 VPS
    /// 标成「本机未配对」，把用户支去做一次白费的重新配对。
    func testPromoteDistinguishesABrokenKeychainFromAMissingCredential() {
        let backend = FakeKeychain()
        backend.refused = { _ in true }

        XCTAssertEqual(
            makeCore(backend).promote(serverID: "vps1"),
            .unreadable(errSecMissingEntitlement)
        )
    }

    func testSaveThrowsOnlyWhenEveryLocationIsRefused() {
        let backend = FakeKeychain()
        backend.refused = { _ in true }
        XCTAssertThrowsError(try makeCore(backend).save(accessToken: "t", serverID: "vps1")) { error in
            XCTAssertEqual(
                error as? PendingNetPairingError,
                .keychain(errSecMissingEntitlement)
            )
        }
    }
}
