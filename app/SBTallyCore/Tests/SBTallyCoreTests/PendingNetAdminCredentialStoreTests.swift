import Foundation
import XCTest
@testable import SBTallyCore

final class PendingNetAdminCredentialStoreTests: XCTestCase {
    func testAdminCredentialUsesSeparateLocalOnlyKeychainService() throws {
        let backend = FakeKeychain()
        let ordinary = PendingNetCredentialStoreCore(
            service: PendingNetCredentialStore.service,
            locations: PendingNetCredentialStore.locations,
            backend: backend
        )
        let admin = PendingNetAdminCredentialStore.makeCore(backend: backend)

        try ordinary.save(accessToken: "ordinary-token", serverID: "server-1")
        try admin.save(accessToken: "admin-token", serverID: "server-1")

        XCTAssertEqual(try ordinary.load(serverID: "server-1"), "ordinary-token")
        XCTAssertEqual(try admin.load(serverID: "server-1"), "admin-token")
        XCTAssertNotEqual(PendingNetAdminCredentialStore.service, PendingNetCredentialStore.service)
        XCTAssertEqual(PendingNetAdminCredentialStore.locations.count, 1)
        XCTAssertFalse(PendingNetAdminCredentialStore.locations[0].synchronizable)

        let adminSlot = backend.slot(
            PendingNetAdminCredentialStore.locations[0],
            service: PendingNetAdminCredentialStore.service,
            serverID: "server-1"
        )
        XCTAssertEqual(backend.items[adminSlot], Data("admin-token".utf8))
    }
}
