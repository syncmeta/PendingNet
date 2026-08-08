import XCTest
@testable import SBTallyCore

/// iCloud 同步这条路到今天为止**没有任何端到端验证**——门户那几步配置还没做，
/// 两台真设备之间同步一次都没跑成过。所以能在单测里钉死的边界一条都不能少：
/// 这个文件盯的全是「真跑起来才会遇到、遇到就很难查」的那几种。
///
/// 与 `PairedVPSStoreTests` 分开放：那边是主干行为（合并规则、两端能互相看见），
/// 这边是边界（平手会不会抖、云端从无到有、坏数据、老存档时间戳）。

/// 比主干测试那份多记一件事：每一次**写云**都留痕。「有没有多余的回写」是
/// 这个文件好几条测试的判据，光看最终内容看不出来。
private final class RecordingCloudStore: UbiquitousKeyValueStoring {
    var storage: [String: Data] = [:]
    private(set) var writes: [Data?] = []
    private(set) var synchronizeCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        storage[key] = data
        writes.append(data)
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }

    /// 云端当前存着的记录（解不出来就当空）。
    var records: [PairedVPSRecord] {
        guard let data = storage[PairedVPSStore.defaultCloudKey] else { return [] }
        return (try? JSONDecoder().decode([PairedVPSRecord].self, from: data)) ?? []
    }

    /// 预置云端内容，并把预置本身产生的写入痕迹抹掉。
    func seed(_ records: [PairedVPSRecord]) throws {
        storage[PairedVPSStore.defaultCloudKey] = try JSONEncoder().encode(records)
        writes.removeAll()
    }
}

private func boundaryRecord(
    id: String,
    name: String? = nil,
    updatedAt: Date
) -> PairedVPSRecord {
    PairedVPSRecord(
        serverID: id,
        name: name ?? "vps-\(id)",
        endpoint: "https://\(id).example.com:7443",
        certificateSHA256: "sha256:" + String(repeating: "a", count: 64),
        deviceID: "device-\(id)",
        capabilities: ["stats"],
        pairedAt: updatedAt,
        updatedAt: updatedAt
    )
}

private func boundaryDefaults(_ name: String) -> UserDefaults {
    let suite = "PairedVPSStoreBoundaryTests.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// 直接写本地镜像，绕过 `upsert`——`upsert` 会盖上「现在」的时间戳，而好几条
/// 测试要的正是「本地这份的时间戳恰好等于云端那份」。
private func seedLocal(_ defaults: UserDefaults, _ records: [PairedVPSRecord]) throws {
    defaults.set(try JSONEncoder().encode(records), forKey: PairedVPSStore.defaultLocalKey)
}

@MainActor
final class PairedVPSStoreBoundaryTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    // MARK: - 平手：留本地，且不能来回抖

    /// 同一台 VPS 两端 `updatedAt` 完全相等时留本地那份——这条主干测试已经
    /// 盯着了。这里盯的是它的**稳定性**：反复拉取不换人，也不再往云里写。
    /// 一旦平手也触发回写，两台设备每次开机就会互相盖来盖去。
    func testTiedRecordNeitherSwitchesNorTriggersMoreCloudWrites() throws {
        let defaults = boundaryDefaults("tie")
        try seedLocal(defaults, [boundaryRecord(id: "a", name: "本机记的名字", updatedAt: early)])
        let cloud = RecordingCloudStore()
        try cloud.seed([boundaryRecord(id: "a", name: "云端记的名字", updatedAt: early)])

        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })
        XCTAssertEqual(store.servers.map(\.name), ["本机记的名字"])

        let writesAfterLaunch = cloud.writes.count
        store.refreshFromCloud()
        store.refreshFromCloud()

        XCTAssertEqual(store.servers.map(\.name), ["本机记的名字"])
        XCTAssertEqual(cloud.writes.count, writesAfterLaunch, "平手不该触发任何额外的回写")
    }

    /// 两台设备共用一份云存储、同一台 VPS 时间戳打平：几轮同步之后必须**停下来**。
    /// 这条是上面那条的真实形态——单看一台设备看不出互相覆盖，得两台一起跑。
    func testTwoDevicesSettleInsteadOfPingPongingForever() throws {
        let cloud = RecordingCloudStore()
        let macDefaults = boundaryDefaults("tie-mac")
        let phoneDefaults = boundaryDefaults("tie-phone")
        try seedLocal(macDefaults, [boundaryRecord(id: "a", name: "Mac 记的", updatedAt: early)])
        try seedLocal(phoneDefaults, [boundaryRecord(id: "a", name: "iPhone 记的", updatedAt: early)])

        let mac = PairedVPSStore(defaults: macDefaults, cloud: cloud, now: { self.late })
        let phone = PairedVPSStore(defaults: phoneDefaults, cloud: cloud, now: { self.late })

        for _ in 0..<3 {
            mac.refreshFromCloud()
            phone.refreshFromCloud()
        }
        let settled = cloud.writes.count
        for _ in 0..<3 {
            mac.refreshFromCloud()
            phone.refreshFromCloud()
        }

        XCTAssertEqual(cloud.writes.count, settled, "平手时两台设备不该没完没了地互相回写")
        // 谁也没把谁的那台弄丢——并集里始终只有这一台。
        XCTAssertEqual(mac.servers.map(\.serverID), ["a"])
        XCTAssertEqual(phone.servers.map(\.serverID), ["a"])
    }

    // MARK: - iCloud 从「不可用」变「可用」

    /// 先离线配对（没登 iCloud / entitlement 没生效），之后 iCloud 可用了：
    /// 本地已有的这台必须在下一次启动时被推上去。少了这一步，这类用户永远
    /// 同步不出去，而且现象是「另一台设备上什么都不出现」，极难往这里查。
    func testRecordsPairedWhileCloudWasUnavailableGetPushedOnceItWorks() {
        let defaults = boundaryDefaults("offline-then-online")
        let offline = PairedVPSStore(defaults: defaults, cloud: nil, now: { self.early })
        offline.upsert(boundaryRecord(id: "a", name: "离线时配的", updatedAt: early))
        XCTAssertFalse(offline.isCloudAvailable)

        let cloud = RecordingCloudStore()
        let online = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })

        XCTAssertTrue(online.isCloudAvailable)
        XCTAssertEqual(online.servers.map(\.serverID), ["a"])
        XCTAssertEqual(cloud.records.map(\.name), ["离线时配的"])
    }

    // MARK: - 并集：谁都不许因为对面没有而消失

    /// 云端有一条本地没有的、本地有一条云端没有的：合并后两条都在，而且**两边**
    /// 都有。只留在内存里不算数——本地独有的那条得补回云端，否则第三台设备
    /// 永远看不到它。
    func testUnionOfBothSidesEndsUpOnBothSides() throws {
        let defaults = boundaryDefaults("union")
        try seedLocal(defaults, [boundaryRecord(id: "onlyLocal", updatedAt: early)])
        let cloud = RecordingCloudStore()
        try cloud.seed([boundaryRecord(id: "onlyCloud", updatedAt: early)])

        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })

        XCTAssertEqual(Set(store.servers.map(\.serverID)), ["onlyLocal", "onlyCloud"])
        XCTAssertEqual(Set(cloud.records.map(\.serverID)), ["onlyLocal", "onlyCloud"])
    }

    /// 云端那份更新、但少了一台：新的那台按 last-writer-wins 换过来，少的那台
    /// **不删**（没有删除语义，缺席不代表删除），并且要补回云端。
    func testNewerCloudRecordWinsWithoutDeletingLocalOnlyOnes() throws {
        let defaults = boundaryDefaults("union-newer")
        try seedLocal(defaults, [
            boundaryRecord(id: "a", name: "本机旧的", updatedAt: early),
            boundaryRecord(id: "b", name: "只有本机有", updatedAt: early),
        ])
        let cloud = RecordingCloudStore()
        try cloud.seed([boundaryRecord(id: "a", name: "云端新的", updatedAt: late)])

        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })

        XCTAssertEqual(store.servers.first { $0.serverID == "a" }?.name, "云端新的")
        XCTAssertEqual(Set(store.servers.map(\.serverID)), ["a", "b"])
        XCTAssertEqual(Set(cloud.records.map(\.serverID)), ["a", "b"], "本机独有的那台要补回云端")
    }

    // MARK: - 云端数据坏掉

    /// 云端那份解不出来（版本不兼容、被别的东西写脏、同步到一半）时，绝不能
    /// 把本地名单清空——那等于一次坏数据就让用户丢掉全部配对。解不出来就当
    /// 云端是空的，本地照旧，并且顺手用一份好的把它盖掉。
    func testCorruptCloudPayloadNeverWipesLocalRecords() throws {
        let defaults = boundaryDefaults("corrupt")
        try seedLocal(defaults, [boundaryRecord(id: "a", updatedAt: early)])
        let cloud = RecordingCloudStore()
        cloud.storage[PairedVPSStore.defaultCloudKey] = Data("<!DOCTYPE html>这不是 JSON".utf8)

        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })

        XCTAssertEqual(store.servers.map(\.serverID), ["a"])
        XCTAssertEqual(cloud.records.map(\.serverID), ["a"], "坏数据该被一份好的盖掉")

        store.refreshFromCloud()
        XCTAssertEqual(store.servers.map(\.serverID), ["a"])
    }

    // MARK: - 老存档的时间戳

    /// 老 iOS 存档连 `pairedAt` 都没有。解码不能炸，而且时间戳必须落在
    /// `distantPast`——要是退回成「现在」，这份没人知道何时写的老记录就会
    /// 压掉另一台设备上真正新改的那份，而且用户看到的是「改的名字自己变回去了」。
    func testLegacyArchiveWithoutTimestampsLosesToARealCloudUpdate() throws {
        let legacyJSON = """
        [{"serverID":"a","name":"老存档里的名字","endpoint":"https://a.example.com:7443",
          "certificateSHA256":"sha256:aa","deviceID":"d1","capabilities":[]}]
        """
        let legacy = try JSONDecoder().decode([PairedVPSRecord].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.map(\.updatedAt), [.distantPast])

        let cloud = RecordingCloudStore()
        try cloud.seed([boundaryRecord(id: "a", name: "另一台设备刚改的", updatedAt: early)])
        let store = PairedVPSStore(defaults: boundaryDefaults("legacy-json"), cloud: cloud, now: { self.late })

        store.adoptLegacy(legacy)

        XCTAssertEqual(store.servers.map(\.name), ["另一台设备刚改的"])
        XCTAssertEqual(cloud.records.map(\.name), ["另一台设备刚改的"])
    }

    /// 反过来：没人认识这台时老存档照收，而且**存进去之后**时间戳仍然是
    /// `distantPast`。这条特意走一遍编解码——`adoptLegacy` 不盖戳只是内存里的
    /// 事，落盘再读回来还得是老时间戳，否则下一次启动它就变成「最新」的了。
    func testAdoptedLegacyRecordKeepsItsDistantPastStampAfterARoundTrip() throws {
        let defaults = boundaryDefaults("legacy-roundtrip")
        let cloud = RecordingCloudStore()
        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })

        var legacy = boundaryRecord(id: "a", name: "老存档", updatedAt: .distantPast)
        legacy.pairedAt = .distantPast
        store.adoptLegacy([legacy])

        XCTAssertEqual(store.servers.map(\.updatedAt), [.distantPast])
        XCTAssertEqual(cloud.records.map(\.updatedAt), [.distantPast])

        // 下一次启动：从磁盘和云里重新解出来，还得是 distantPast。
        let relaunched = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })
        XCTAssertEqual(relaunched.servers.map(\.updatedAt), [.distantPast])
    }

    // MARK: - 首次同步不能发布空名单

    /// 全新设备第一次启动：`NSUbiquitousKeyValueStore` 的本地缓存还没下下来，
    /// `data(forKey:)` 回 nil，`servers` 也是空的。此时绝不能把这份空名单发布
    /// 到云上；KVS 是按键 last-writer-wins，会盖掉另一台已经同步好的名单。
    ///
    /// 要命的是它**不会自愈**：对面收到空名单后走 `merge(local:remote:)`，并集
    /// 语义下结果与自己原来的一模一样，`mergeCloudIntoLocal` 因此提前返回、
    /// 不回写——云端就一直空着。（本地非空时反而没这个问题：对面合并后内容
    /// 变了，会把并集推回去，云端自己就补齐了。）
    ///
    /// 现象正是最难查的那种：两台设备各自都好好的，就是同步不过去。
    func testFreshDeviceMustNotPublishAnEmptyListOverTheCloud() {
        let cloud = RecordingCloudStore()
        _ = PairedVPSStore(defaults: boundaryDefaults("fresh"), cloud: cloud, now: { self.early })
        XCTAssertTrue(cloud.writes.isEmpty, "本地和云端都还是空的，不该往云里写一份空名单")
    }

    /// 老版本已经把云端盖成空名单时，新版本收到同步/主动刷新后要把本机仍有的
    /// 记录补回去；不能因为内存里的并集没变化就提前返回。
    func testLocalRecordsRepairAnEmptyCloudValueEvenWhenTheUnionIsUnchanged() throws {
        let defaults = boundaryDefaults("repair-empty-cloud")
        try seedLocal(defaults, [boundaryRecord(id: "a", updatedAt: early)])
        let cloud = RecordingCloudStore()
        let store = PairedVPSStore(defaults: defaults, cloud: cloud, now: { self.late })
        XCTAssertEqual(cloud.records.map(\.serverID), ["a"])

        try cloud.seed([])
        let writesBeforeRefresh = cloud.writes.count
        store.refreshFromCloud()

        XCTAssertEqual(cloud.records.map(\.serverID), ["a"])
        XCTAssertEqual(cloud.writes.count, writesBeforeRefresh + 1)
    }

    // MARK: - iCloud 主动推送

    /// `didChangeExternallyNotification` 是真同步唯一的实时通道，也是最没法
    /// 手工验的一条。这里把它当成黑盒打一枪：推送到达时要合并进来，并且回调
    /// 界面（选中项等派生状态靠它刷新）。
    func testExternalCloudPushMergesAndNotifiesTheUI() throws {
        let cloud = RecordingCloudStore()
        let store = PairedVPSStore(defaults: boundaryDefaults("push"), cloud: cloud, now: { self.early })
        XCTAssertTrue(store.servers.isEmpty)

        let notified = expectation(description: "onExternalChange")
        store.onExternalChange = { notified.fulfill() }

        try cloud.seed([boundaryRecord(id: "pushed", name: "另一台配的", updatedAt: late)])
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )

        wait(for: [notified], timeout: 5)
        XCTAssertEqual(store.servers.map(\.name), ["另一台配的"])
    }
}
