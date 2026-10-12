import XCTest
@testable import SBTallyCore

final class PendingNetSystemDNSTests: XCTestCase {
    final class Store {
        var values: [String: Data] = ["ethernet": Data(#"{"SearchDomains":["home"],"ServerAddresses":["223.5.5.5"]}"#.utf8)]
        var services = ["ethernet", "wifi"]
        var journal: Data?
        var failService: String?
        var failSave = false
        var writes = [String]()
        var manager: PendingNetSystemDNS {
            PendingNetSystemDNS(backend: .init(services: { self.services }, read: { self.values[$0] },
                write: { name, expected, data in
                    self.writes.append(name)
                    guard self.values[name] == expected else { throw PendingNetSystemDNS.Failure.changedService(name) }
                    if name == self.failService { throw NSError(domain: "test", code: 1) }
                    self.values[name] = data
                }, load: { self.journal }, save: {
                    if self.failSave { throw NSError(domain: "disk", code: 1) }
                    self.journal = $0
                }))
        }
    }
    func testReadinessFailureNeverChangesSettings() {
        let store = Store()
        XCTAssertThrowsError(try store.manager.acquire { throw NSError(domain: "ready", code: 1) })
        XCTAssertTrue(store.writes.isEmpty); XCTAssertNil(store.journal)
    }
    func testRestartRestoresStaticAndAutomaticSettingsAndPreservesOptions() throws {
        let store = Store(); let original = store.values
        try store.manager.acquire {}
        let applied = try XCTUnwrap(store.values["ethernet"])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: applied) as? [String: Any])
        XCTAssertEqual(value["SearchDomains"] as? [String], ["home"])
        XCTAssertEqual(value["ServerAddresses"] as? [String], ["127.0.0.1"])
        // A new instance reads the persisted ownership, never snapshots itself.
        try store.manager.acquire {}
        try store.manager.release()
        XCTAssertEqual(store.values, original); XCTAssertNil(store.journal)
    }
    func testPartialFailureRestoresPriorServices() {
        let store = Store(); let original = store.values
        store.failService = "wifi"
        XCTAssertThrowsError(try store.manager.acquire {})
        XCTAssertEqual(store.values, original); XCTAssertNil(store.journal)
    }
    func testJournalFailureOccursBeforeMutation() {
        let store = Store(); store.failSave = true
        XCTAssertThrowsError(try store.manager.acquire {})
        XCTAssertTrue(store.writes.isEmpty)
    }
    func testUserEditIsNotOverwrittenOnRelease() throws {
        let store = Store()
        try store.manager.acquire {}
        let edit = Data(#"{"ServerAddresses":["9.9.9.9"]}"#.utf8)
        store.values["ethernet"] = edit
        try store.manager.release()
        XCTAssertEqual(store.values["ethernet"], edit); XCTAssertNil(store.journal)
    }
    func testFailedRestoreKeepsJournalForRetry() throws {
        let store = Store(); let original = store.values
        try store.manager.acquire {}
        store.failService = "ethernet"
        XCTAssertThrowsError(try store.manager.release())
        XCTAssertNotNil(store.journal)
        store.failService = nil
        try store.manager.release()
        XCTAssertEqual(store.values, original); XCTAssertNil(store.journal)
    }
    func testSearchDomainEditKeepsUserEditAndRestoresOnlyOurServerAddresses() throws {
        let store = Store()
        try store.manager.acquire {}
        store.values["ethernet"] = Data(#"{"SearchDomains":["work"],"ServerAddresses":["127.0.0.1"]}"#.utf8)
        try store.manager.acquire {}
        try store.manager.release()
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.values["ethernet"])) as? [String: Any])
        XCTAssertEqual(value["SearchDomains"] as? [String], ["work"])
        XCTAssertEqual(value["ServerAddresses"] as? [String], ["223.5.5.5"])
    }
    func testNewNetworkServiceGetsItsOwnSnapshot() throws {
        let store = Store()
        try store.manager.acquire {}
        let original = Data(#"{"ServerAddresses":["1.0.0.1"]}"#.utf8)
        store.services.append("usb"); store.values["usb"] = original
        try store.manager.acquire {}
        XCTAssertNotEqual(store.values["usb"], original)
        try store.manager.release()
        XCTAssertEqual(store.values["usb"], original)
    }
}
