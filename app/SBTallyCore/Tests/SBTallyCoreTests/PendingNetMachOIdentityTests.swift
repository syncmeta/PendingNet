import XCTest
@testable import SBTallyCore

final class PendingNetMachOIdentityTests: XCTestCase {
    private func thin(_ id: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 56)
        func put(_ number: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: number >> (i*8)) }
        }
        put(0xfeedfacf, at: 0); put(1, at: 16); put(24, at: 20)
        put(0x1b, at: 32); put(24, at: 36)
        for i in 40..<56 { bytes[i] = id }
        return Data(bytes)
    }

    func testRecognizesMappedUUIDWithoutDependingOnModificationTime() {
        XCTAssertEqual(PendingNetMachOIdentity.identifiers(in: thin(1)), [String(repeating: "01", count: 16)])
        XCTAssertFalse(PendingNetMachOIdentity.identifiers(in: thin(2)).contains(String(repeating: "01", count: 16)))
    }

    func testUniversalAcceptsBothNativeAndRosettaSliceIdentities() {
        var bytes = [UInt8](repeating: 0, count: 48)
        func put(_ number: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: number >> ((3-i)*8)) }
        }
        put(0xcafebabe, at: 0); put(2, at: 4)
        put(48, at: 16); put(56, at: 20)
        put(104, at: 36); put(56, at: 40)
        let data = Data(bytes) + thin(1) + thin(2)
        XCTAssertEqual(PendingNetMachOIdentity.identifiers(in: data), [String(repeating: "01", count: 16), String(repeating: "02", count: 16)])
    }

    func testRejectsTruncatedOrMalformedLoadCommands() {
        let good = thin(1)
        for size in [0, 3, 31, 40, 55] {
            XCTAssertTrue(PendingNetMachOIdentity.identifiers(in: Data(good.prefix(size))).isEmpty)
        }
        var bad = good
        bad[36] = 255
        XCTAssertTrue(PendingNetMachOIdentity.identifiers(in: bad).isEmpty)
        XCTAssertTrue(PendingNetMachOIdentity.identifiers(in: Data("not Mach-O".utf8)).isEmpty)
    }
}
