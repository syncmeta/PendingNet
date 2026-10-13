import Darwin
import Foundation

public enum PendingNetLatencyMethod: String, CaseIterable, Identifiable, Sendable {
    case tcp, icmp
    public var id: String { rawValue }
    public static let preferenceKey = "pendingnet.latency-method.v1"
}

/// Unprivileged Darwin datagram ICMP sockets, as used by Apple's SimplePing.
/// The nonce is checked because concurrent datagram sockets can see each
/// other's echoes. ICMP is host reachability, not proxy/service validation.
public enum PendingNetICMPProbe {
    public static let echo: PendingNetLatencyTester.Probe = { host, _, timeout in
        try await withCheckedThrowingContinuation { continuation in
            let completion = EchoCompletion(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.001, timeout)) {
                completion.finish(.failure(PendingNetLatencyError.timedOut))
            }
            DispatchQueue.global().async {
                completion.finish(Result { try ping(host: host, timeout: timeout) })
            }
        }
    }

    static func checksum(_ packet: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index < packet.count {
            sum += UInt32(packet[index]) << 8
            if index + 1 < packet.count { sum += UInt32(packet[index + 1]) }
            index += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func matchesReply(_ bytes: [UInt8], ipv6: Bool, nonce: [UInt8], sequence: UInt16) -> Bool {
        var offset = 0
        if !ipv6, let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 15) * 4
            guard offset >= 20, bytes.count >= offset + 8, bytes[9] == UInt8(IPPROTO_ICMP) else { return false }
        }
        guard bytes.count == offset + 8 + nonce.count,
              bytes[offset] == (ipv6 ? 129 : 0), bytes[offset + 1] == 0,
              bytes[offset + 6] == UInt8(sequence >> 8), bytes[offset + 7] == UInt8(truncatingIfNeeded: sequence),
              Array(bytes[(offset + 8)...]) == nonce else { return false }
        return ipv6 || checksum(Array(bytes[offset...])) == 0
    }

    static func ping(host: String, timeout: TimeInterval) throws -> Int {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else {
            throw PendingNetLatencyError.unresolvableAddress
        }
        defer { freeaddrinfo(first) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw PendingNetLatencyError.timedOut }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var fd: Int32 = -1
        var ipv6 = false
        while let entry = cursor {
            let address = entry.pointee
            if address.ai_family == AF_INET || address.ai_family == AF_INET6 {
                fd = socket(address.ai_family, SOCK_DGRAM, address.ai_family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
                if fd >= 0 {
                    if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 {
                        ipv6 = address.ai_family == AF_INET6
                        break
                    }
                    close(fd); fd = -1
                }
            }
            cursor = entry.pointee.ai_next
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        let nonce = Array(UUID().uuidString.utf8)
        let sequence = UInt16.random(in: 0...UInt16.max)
        let identifier = UInt16.random(in: 0...UInt16.max)
        var packet: [UInt8] = [ipv6 ? 128 : 8, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(truncatingIfNeeded: identifier),
            UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence)] + nonce
        if !ipv6 {
            let value = checksum(packet)
            packet[2] = UInt8(value >> 8); packet[3] = UInt8(truncatingIfNeeded: value)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let remaining = (deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining + 1, 500)))
            if ready < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count > 0, matchesReply(Array(buffer.prefix(count)), ipv6: ipv6, nonce: nonce, sequence: sequence) {
                return max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
            }
        }
        throw PendingNetLatencyError.timedOut
    }
}

private final class EchoCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    init(_ continuation: CheckedContinuation<Int, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Int, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
