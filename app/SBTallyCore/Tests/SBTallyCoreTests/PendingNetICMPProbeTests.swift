import XCTest
@testable import SBTallyCore

final class PendingNetICMPProbeTests: XCTestCase {
    func testEchoReplyRejectsWrongProbeAndCorruption() {
        let nonce: [UInt8] = [1, 2, 3, 4, 5]
        var packet: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 7] + nonce
        let checksum = PendingNetICMPProbe.checksum(packet)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(truncatingIfNeeded: checksum)
        XCTAssertTrue(PendingNetICMPProbe.matchesReply(packet, ipv6: false, nonce: nonce, sequence: 7))
        XCTAssertFalse(PendingNetICMPProbe.matchesReply(packet, ipv6: false, nonce: [9, 9, 9, 9, 9], sequence: 7))
        XCTAssertFalse(PendingNetICMPProbe.matchesReply(packet, ipv6: false, nonce: nonce, sequence: 8))
        packet[4] ^= 1
        XCTAssertFalse(PendingNetICMPProbe.matchesReply(packet, ipv6: false, nonce: nonce, sequence: 7))
    }
    func testIPv4HeaderAndIPv6Reply() {
        let nonce: [UInt8] = [8, 9]
        var packet: [UInt8] = [0, 0, 0, 0, 1, 2, 0, 3] + nonce
        let checksum = PendingNetICMPProbe.checksum(packet)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(truncatingIfNeeded: checksum)
        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45; header[9] = 1
        XCTAssertTrue(PendingNetICMPProbe.matchesReply(header + packet, ipv6: false, nonce: nonce, sequence: 3))
        XCTAssertFalse(PendingNetICMPProbe.matchesReply([0x45], ipv6: false, nonce: nonce, sequence: 3))
        packet[0] = 129
        XCTAssertTrue(PendingNetICMPProbe.matchesReply(packet, ipv6: true, nonce: nonce, sequence: 3))
    }
    func testRealUnprivilegedLoopbackEcho() async throws {
        let milliseconds = try await PendingNetICMPProbe.echo("127.0.0.1", 0, 2)
        XCTAssertGreaterThanOrEqual(milliseconds, 1)
        XCTAssertLessThan(milliseconds, 2000)
    }
}
