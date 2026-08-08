import XCTest
@testable import SBTallyCore

private final class FakeCloudStore: UbiquitousKeyValueStoring {
    var storage: [String: Data] = [:]
    private(set) var synchronizeCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}

private func makeRecord(
    id: String,
    name: String? = nil,
    protocols: [String]? = nil,
    updatedAt: Date
) -> PairedVPSRecord {
    PairedVPSRecord(
        serverID: id,
        name: name ?? "vps-\(id)",
        endpoint: "https://\(id).example.com:7443",
        certificateSHA256: "sha256:" + String(repeating: "a", count: 64),
        deviceID: "device-\(id)",
        capabilities: ["stats"],
        nodeProtocols: protocols,
        pairedAt: updatedAt,
        updatedAt: updatedAt
    )
}

private func makeDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "PairedVPSStoreTests.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

final class PairedVPSMergeTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    func testMergeTakesUnionAcrossDevices() {
        let merged = PairedVPSMerge.merge(
            local: [makeRecord(id: "mac", updatedAt: early)],
            remote: [makeRecord(id: "phone", updatedAt: early)]
        )
        XCTAssertEqual(merged.map(\.serverID), ["mac", "phone"])
    }

    func testMergeKeepsNewerRecordForSameServer() {
        let merged = PairedVPSMerge.merge(
            local: [makeRecord(id: "a", name: "老名字", updatedAt: early)],
            remote: [makeRecord(id: "a", name: "新名字", updatedAt: late)]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "新名字")
    }

    func testMergeKeepsLocalWhenRemoteIsOlder() {
        let merged = PairedVPSMerge.merge(
            local: [makeRecord(id: "a", name: "本机更新过", updatedAt: late)],
            remote: [makeRecord(id: "a", name: "云端旧的", updatedAt: early)]
        )
        XCTAssertEqual(merged.map(\.name), ["本机更新过"])
    }

    func testMergeKeepsLocalOnTie() {
        let merged = PairedVPSMerge.merge(
            local: [makeRecord(id: "a", name: "本机", updatedAt: early)],
            remote: [makeRecord(id: "a", name: "云端", updatedAt: early)]
        )
        XCTAssertEqual(merged.map(\.name), ["本机"])
    }

    /// 没有删除语义：云端那份缺了一台，不代表要把本机这台删掉。
    func testMergeNeverDropsRecordsMissingOnTheOtherSide() {
        let merged = PairedVPSMerge.merge(
            local: [makeRecord(id: "a", updatedAt: early), makeRecord(id: "b", updatedAt: early)],
            remote: [makeRecord(id: "a", updatedAt: late)]
        )
        XCTAssertEqual(merged.map(\.serverID), ["a", "b"])
    }

    func testSortIsStableAcrossDevicesForEqualNames() {
        let records = [
            makeRecord(id: "z", name: "同名", updatedAt: early),
            makeRecord(id: "a", name: "同名", updatedAt: early),
        ]
        XCTAssertEqual(PairedVPSMerge.sorted(records).map(\.serverID), ["a", "z"])
        XCTAssertEqual(PairedVPSMerge.sorted(records.reversed()).map(\.serverID), ["a", "z"])
    }
}

final class PairedVPSRecordDecodingTests: XCTestCase {
    /// macOS 0.3.18 及以前的存档形状：有 pairedAt，没有 updatedAt。
    func testLegacyMacRecordDecodesWithUpdatedAtFallingBackToPairedAt() throws {
        let json = """
        [{"serverID":"a","name":"vps","endpoint":"https://a.example.com:7443",
          "certificateSHA256":"sha256:aa","deviceID":"d1","capabilities":["stats"],
          "pairedAt":701000000}]
        """
        let decoded = try JSONDecoder().decode([PairedVPSRecord].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].updatedAt, decoded[0].pairedAt)
        XCTAssertNil(decoded[0].nodeProtocols)
    }

    /// iOS 0.3.18 及以前的存档形状：连 pairedAt 都没有。
    func testLegacyIOSRecordDecodesWithoutTimestamps() throws {
        let json = """
        [{"serverID":"a","name":"vps","endpoint":"https://a.example.com:7443",
          "certificateSHA256":"sha256:aa","deviceID":"d1","capabilities":[],
          "nodeProtocols":["VLESS"]}]
        """
        let decoded = try JSONDecoder().decode([PairedVPSRecord].self, from: Data(json.utf8))
        XCTAssertEqual(decoded[0].pairedAt, .distantPast)
        XCTAssertEqual(decoded[0].updatedAt, .distantPast)
        XCTAssertEqual(decoded[0].nodeProtocols, ["VLESS"])
    }

    func testRoundTripKeepsTimestamps() throws {
        let record = makeRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 12_345))
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([PairedVPSRecord].self, from: data), [record])
    }
}

@MainActor
final class PairedVPSStoreTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    func testUpsertWritesBothLocalMirrorAndCloud() {
        let defaults = makeDefaults("upsert")
        let cloud = FakeCloudStore()
        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })
        store.upsert(makeRecord(id: "a", updatedAt: self.early))

        XCTAssertEqual(store.servers.map(\.serverID), ["a"])
        XCTAssertNotNil(defaults.data(forKey: PairedVPSStore.defaultLocalKey))
        XCTAssertNotNil(cloud.storage[PairedVPSStore.defaultCloudKey])
        // 本机写入盖上本机的时间戳，否则跨设备比不出谁新。
        XCTAssertEqual(store.servers[0].updatedAt, late)
    }

    /// 「Mac 上配好的 VPS 出现在 iPhone 列表里」的最小复现：两个 store 共用
    /// 同一个云存储，各自的本地镜像互不相干。
    func testSecondDeviceSeesRecordPairedOnTheFirst() {
        let cloud = FakeCloudStore()
        let mac = PairedVPSStore(defaults: makeDefaults("mac"), cloud: cloud, now: { self.early })
        mac.upsert(makeRecord(id: "vps1", name: "东京", updatedAt: early))

        let phone = PairedVPSStore(defaults: makeDefaults("phone"), cloud: cloud, now: { self.late })
        XCTAssertEqual(phone.servers.map(\.name), ["东京"])
    }

    func testExternalCloudChangeIsPickedUpOnRefresh() {
        let cloud = FakeCloudStore()
        let store = PairedVPSStore(defaults: makeDefaults("external"), cloud: cloud, now: { self.early })
        XCTAssertTrue(store.servers.isEmpty)

        cloud.storage[PairedVPSStore.defaultCloudKey] =
            try? JSONEncoder().encode([makeRecord(id: "b", updatedAt: late)])
        store.refreshFromCloud()

        XCTAssertEqual(store.servers.map(\.serverID), ["b"])
        XCTAssertGreaterThan(cloud.synchronizeCount, 0)
    }

    /// 云端更新的那份覆盖本地旧的，本地独有的那台留着。
    func testRefreshMergesInsteadOfReplacing() {
        let cloud = FakeCloudStore()
        let store = PairedVPSStore(defaults: makeDefaults("merge"), cloud: cloud, now: { self.early })
        store.upsert(makeRecord(id: "a", name: "本机旧的", updatedAt: early))
        store.upsert(makeRecord(id: "onlyLocal", updatedAt: early))

        cloud.storage[PairedVPSStore.defaultCloudKey] =
            try? JSONEncoder().encode([makeRecord(id: "a", name: "云端新的", updatedAt: late)])
        store.refreshFromCloud()

        XCTAssertEqual(Set(store.servers.map(\.serverID)), ["a", "onlyLocal"])
        XCTAssertEqual(store.servers.first { $0.serverID == "a" }?.name, "云端新的")
    }

    /// iCloud 用不了（没登录 / 没 entitlement / ad-hoc 开发构建）时一切照旧
    /// 纯本地工作：读得到上次存的，写得进去，不抛错。
    func testWorksPurelyLocallyWhenCloudUnavailable() {
        let defaults = makeDefaults("nocloud")
        let first = PairedVPSStore(defaults: defaults, cloud: nil, now: { self.early })
        first.upsert(makeRecord(id: "a", updatedAt: early))
        XCTAssertFalse(first.isCloudAvailable)

        let second = PairedVPSStore(defaults: defaults, cloud: nil, now: { self.late })
        XCTAssertEqual(second.servers.map(\.serverID), ["a"])
        second.refreshFromCloud()
        XCTAssertEqual(second.servers.map(\.serverID), ["a"])
    }

    /// 老存档搬进来时不盖新时间戳，否则会压住对面真正更新的那一份。
    func testAdoptLegacyDoesNotOutrankNewerCloudRecord() {
        let cloud = FakeCloudStore()
        cloud.storage[PairedVPSStore.defaultCloudKey] =
            try? JSONEncoder().encode([makeRecord(id: "a", name: "云端新的", updatedAt: late)])
        let store = PairedVPSStore(defaults: makeDefaults("legacy"), cloud: cloud, now: { self.late })

        store.adoptLegacy([makeRecord(id: "a", name: "本机老存档", updatedAt: early)])

        XCTAssertEqual(store.servers.map(\.name), ["云端新的"])
    }

    func testAdoptLegacyKeepsRecordsTheCloudNeverHeardOf() {
        let store = PairedVPSStore(defaults: makeDefaults("legacy2"), cloud: FakeCloudStore(), now: { self.late })
        store.adoptLegacy([makeRecord(id: "old", updatedAt: .distantPast)])
        XCTAssertEqual(store.servers.map(\.serverID), ["old"])
    }
}
