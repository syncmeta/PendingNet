import Foundation

/// LC_UUID identifies linked code, independently of signing or file timestamps.
/// All universal slices are accepted because launchd and the app may use
/// different architectures (for example, a Rosetta app and a native helper).
public enum PendingNetMachOIdentity {
    public static func identifiers(in data: Data) -> Set<String> {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int, _ big: Bool) -> UInt64? {
            guard offset >= 0, count <= 8, offset <= bytes.count - count else { return nil }
            var result: UInt64 = 0
            for i in 0..<count { result = (result << 8) | UInt64(bytes[offset + (big ? i : count - 1 - i)]) }
            return result
        }
        func thin(_ offset: Int, _ length: Int) -> String? {
            guard length >= 32, offset >= 0, offset <= bytes.count - length,
                  let magic = number(offset, 4, false), magic == 0xfeedfacf || magic == 0xcffaedfe else { return nil }
            let big = magic == 0xcffaedfe
            guard let count = number(offset + 16, 4, big), let size = number(offset + 20, 4, big),
                  count <= 4096, size <= UInt64(length - 32) else { return nil }
            var cursor = offset + 32
            let end = cursor + Int(size)
            for _ in 0..<count {
                guard cursor <= end - 8, let command = number(cursor, 4, big), let size = number(cursor + 4, 4, big),
                      size >= 8, size <= UInt64(end - cursor) else { return nil }
                if command == 0x1b {
                    guard size == 24 else { return nil }
                    return bytes[(cursor + 8)..<(cursor + 24)].map { String(format: "%02x", $0) }.joined()
                }
                cursor += Int(size)
            }
            return nil
        }
        guard let magic = number(0, 4, true) else { return [] }
        if [UInt64(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let big = magic == 0xcafebabe || magic == 0xcafebabf
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let stride = wide ? 32 : 20
            guard let count = number(4, 4, big), count > 0, count <= 64,
                  8 + Int(count) * stride <= bytes.count else { return [] }
            var result: Set<String> = []
            for i in 0..<Int(count) {
                let entry = 8 + i * stride
                guard let offset = number(entry + 8, wide ? 8 : 4, big),
                      let length = number(entry + (wide ? 16 : 12), wide ? 8 : 4, big),
                      offset <= UInt64(bytes.count), length <= UInt64(bytes.count) - offset,
                      let id = thin(Int(offset), Int(length)) else { return [] }
                result.insert(id)
            }
            return result
        }
        return thin(0, bytes.count).map { [$0] } ?? []
    }
}
