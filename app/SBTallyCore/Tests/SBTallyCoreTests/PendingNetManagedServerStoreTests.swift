import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetManagedServerStoreTests: XCTestCase {
    func testManagementMetadataStaysSeparateFromProxyList() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PendingNetManagedServerStoreTests.\(UUID().uuidString)"))
        let managed = PendingNetManagedServerStore(defaults: defaults)
        let server = PendingNetManagedServer(
            serverID: "pns_admin_test", name: "Test Server",
            endpoint: "https://203.0.113.10:7443",
            certificateSHA256: "sha256:" + String(repeating: "ab", count: 32),
            deviceID: "dev_admin"
        )
        try managed.upsert(server)
        XCTAssertEqual(PendingNetManagedServerStore(defaults: defaults).servers, [server])
        XCTAssertNil(defaults.data(forKey: PairedVPSStore.defaultLocalKey))
        XCTAssertNotEqual(PendingNetManagedServerStore.defaultLocalKey, PairedVPSStore.defaultCloudKey)

        await MainActor.run {
            let ordinary = PairedVPSStore(defaults: defaults, cloud: nil)
            XCTAssertTrue(ordinary.servers.isEmpty)
        }
    }

    func testCorruptLocalMetadataIsNotOverwritten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PendingNetManagedServerStoreTests.\(UUID().uuidString)"))
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: PendingNetManagedServerStore.defaultLocalKey)
        let store = PendingNetManagedServerStore(defaults: defaults)
        let server = PendingNetManagedServer(
            serverID: "pns_admin_test", name: "Test Server",
            endpoint: "https://203.0.113.10:7443",
            certificateSHA256: "sha256:" + String(repeating: "ab", count: 32),
            deviceID: "dev_admin"
        )
        XCTAssertThrowsError(try store.upsert(server)) { error in
            XCTAssertTrue(error is PendingNetManagedServerStoreError)
        }
        XCTAssertThrowsError(try store.ensureWritable()) { error in
            XCTAssertTrue(error is PendingNetManagedServerStoreError)
        }
        XCTAssertEqual(defaults.data(forKey: PendingNetManagedServerStore.defaultLocalKey), corrupt)
    }

    func testDuplicateServerIDsAreRejectedWithoutOverwritingMetadata() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PendingNetManagedServerStoreTests.\(UUID().uuidString)"))
        let server = PendingNetManagedServer(
            serverID: "pns_admin_test", name: "Test Server",
            endpoint: "https://203.0.113.10:7443",
            certificateSHA256: "sha256:" + String(repeating: "ab", count: 32),
            deviceID: "dev_admin"
        )
        let duplicate = try JSONEncoder().encode([server, server])
        defaults.set(duplicate, forKey: PendingNetManagedServerStore.defaultLocalKey)

        let store = PendingNetManagedServerStore(defaults: defaults)
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertThrowsError(try store.ensureWritable()) { error in
            XCTAssertTrue(error is PendingNetManagedServerStoreError)
        }
        XCTAssertEqual(defaults.data(forKey: PendingNetManagedServerStore.defaultLocalKey), duplicate)
    }
}
