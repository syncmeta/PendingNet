import Foundation
import Security
import XCTest
@testable import SBTallyCore

/// 内存版钥匙串。真钥匙串在未签名的测试二进制里碰不得（数据保护钥匙串会直接
/// 回 -34018），迁移逻辑只能这样才测得到。
private final class FakeKeychain: PendingNetKeychainBackend, @unchecked Sendable {
    struct Key: Hashable {
        var service: String
        var account: String
        var synchronizable: Bool
        var accessGroup: String?
        var dataProtection: Bool
    }

    var items: [Key: Data] = [:]
    /// 模拟「没有这个 entitlement」：命中的位置一律回 errSecMissingEntitlement。
    var refused: (Key) -> Bool = { _ in false }
    private(set) var deleted: [Key] = []

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

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, data: Data?) {
        let key = key(from: query)
        if refused(key) { return (errSecMissingEntitlement, nil) }
        guard let data = items[key] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        let key = key(from: attributes)
        if refused(key) { return errSecMissingEntitlement }
        items[key] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        let key = key(from: query)
        if refused(key) { return errSecMissingEntitlement }
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        let key = key(from: query)
        if refused(key) { return errSecMissingEntitlement }
        deleted.append(key)
        guard items.removeValue(forKey: key) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

final class PendingNetCredentialStoreTests: XCTestCase {
    private let service = PendingNetCredentialStore.service
    private let shared = PendingNetCredentialStore.sharedAccessGroup
    private let locations = PendingNetCredentialStore.locations

    private func makeCore(_ backend: FakeKeychain) -> PendingNetCredentialStoreCore {
        PendingNetCredentialStoreCore(service: service, locations: locations, backend: backend)
    }

    private func syncedKey(_ serverID: String) -> FakeKeychain.Key {
        .init(
            service: service,
            account: serverID,
            synchronizable: true,
            accessGroup: shared,
            dataProtection: true
        )
    }

    /// 0.3.18 及以前写进去的形状：普通 file-based 钥匙串、不同步、无共享组。
    private func legacyKey(_ serverID: String) -> FakeKeychain.Key {
        .init(
            service: service,
            account: serverID,
            synchronizable: false,
            accessGroup: nil,
            dataProtection: legacyUsesDataProtection
        )
    }

    #if os(macOS)
    private let legacyUsesDataProtection = false
    #else
    private let legacyUsesDataProtection = true
    #endif

    func testSaveLandsInTheSynchronizableSharedGroup() throws {
        let backend = FakeKeychain()
        try makeCore(backend).save(accessToken: "token-1", serverID: "vps1")
        XCTAssertEqual(backend.items[syncedKey("vps1")], Data("token-1".utf8))
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
        backend.items[legacyKey("vps1")] = Data("legacy-token".utf8)
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    func testLegacyTokenIsMigratedToTheSynchronizableItem() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey("vps1")] = Data("legacy-token".utf8)

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        // 搬上去了，而且老条目清掉了（否则下次读可能读回旧值）。
        XCTAssertEqual(backend.items[syncedKey("vps1")], Data("legacy-token".utf8))
        XCTAssertNil(backend.items[legacyKey("vps1")])
        // 搬完再读一次拿到的还是同一个令牌。
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")
    }

    /// 没有 entitlement 的构建（本地 ad-hoc 签名就是这样）：同步条目写不进去，
    /// 迁移必须原地放弃——老条目留着，令牌照常读得到，不抛错。
    func testMigrationIsLosslessWhenICloudKeychainIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey("vps1")] = Data("legacy-token".utf8)
        backend.refused = { $0.synchronizable }

        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "legacy-token")

        XCTAssertEqual(backend.items[legacyKey("vps1")], Data("legacy-token".utf8))
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    /// 同上，写新令牌时也要能退回老位置，不能因为没 entitlement 就配对失败。
    func testSaveFallsBackToTheLocalItemWhenICloudKeychainIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.refused = { $0.synchronizable }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")

        XCTAssertEqual(backend.items[legacyKey("vps1")], Data("token-1".utf8))
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    /// 只有共享组不可用（entitlement 没配全）时退到 App 默认组，仍然是同步条目。
    func testFallsBackToTheDefaultAccessGroupWhenTheSharedGroupIsUnavailable() throws {
        let backend = FakeKeychain()
        backend.refused = { $0.accessGroup != nil }
        let core = makeCore(backend)

        try core.save(accessToken: "token-1", serverID: "vps1")

        let defaultGroup = FakeKeychain.Key(
            service: service,
            account: "vps1",
            synchronizable: true,
            accessGroup: nil,
            dataProtection: true
        )
        XCTAssertEqual(backend.items[defaultGroup], Data("token-1".utf8))
        XCTAssertEqual(try core.load(serverID: "vps1"), "token-1")
    }

    /// 同步条目优先于老条目：两份都在时读到的是新的那份。
    func testSynchronizableItemWinsOverALeftoverLegacyItem() throws {
        let backend = FakeKeychain()
        backend.items[syncedKey("vps1")] = Data("new".utf8)
        backend.items[legacyKey("vps1")] = Data("stale".utf8)
        XCTAssertEqual(try makeCore(backend).load(serverID: "vps1"), "new")
    }

    func testSaveClearsLeftoverLegacyItem() throws {
        let backend = FakeKeychain()
        backend.items[legacyKey("vps1")] = Data("stale".utf8)
        try makeCore(backend).save(accessToken: "new", serverID: "vps1")
        XCTAssertNil(backend.items[legacyKey("vps1")])
        XCTAssertEqual(backend.items[syncedKey("vps1")], Data("new".utf8))
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
