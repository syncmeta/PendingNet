import XCTest
@testable import SBTallyCore

final class PendingNetStartupPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "PendingNetStartupPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testConnectionIntentDefaultsToOffAndRoundTrips() {
        let defaults = defaults()
        let store = PendingNetStartupPreferences(defaults: defaults)
        XCTAssertFalse(store.wasConnected)
        store.rememberConnected(true)
        XCTAssertTrue(PendingNetStartupPreferences(defaults: defaults).wasConnected)
        store.rememberConnected(false)
        XCTAssertFalse(store.wasConnected)
    }

    func testSelectorChoicesRoundTripIndependently() {
        let defaults = defaults()
        let store = PendingNetSelectorPreferences(defaults: defaults)
        store.remember(selector: "proxy", selection: "pendingnet-vps-a")
        store.remember(selector: "pendingnet-vps-a", selection: "vless-reality")
        XCTAssertEqual(store.selections, [
            "proxy": "pendingnet-vps-a",
            "pendingnet-vps-a": "vless-reality",
        ])
    }

    func testRestoreDropsRemovedChoicesAndAlreadyAppliedOnes() {
        let defaults = defaults()
        let store = PendingNetSelectorPreferences(defaults: defaults)
        store.remember(selector: "gone", selection: "old")
        store.remember(selector: "proxy", selection: "vps-b")
        store.remember(selector: "vps-b", selection: "hy2")

        let proxies = [
            "proxy": Proxy(type: "Selector", now: "vps-a", all: ["vps-a", "vps-b"]),
            "vps-b": Proxy(type: "Selector", now: "hy2", all: ["reality", "hy2"]),
        ]
        let restored = store.restorableSelections(in: proxies)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.0, "proxy")
        XCTAssertEqual(restored.first?.1, "vps-b")
    }
}
