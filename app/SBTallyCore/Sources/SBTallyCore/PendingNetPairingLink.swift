import Foundation

/// 配对凭据的第二种形态：一条 `pendingnet://pair?v=1&d=…` 链接。
///
/// `d` 里装的是 `.pdn` 那份 JSON **整体**做 base64url（无填充）的结果，不拆字段
/// —— 解码完直接交给 `PendingNetPairingFile.decode`，多一种传输形态不等于多一份
/// 解析实现，也就没有字段在两条路之间漂移的余地。
///
/// 生成端只有一处：Go 侧 `internal/pairing` 的 `File.URL`。这里是与 `ParseURL`
/// 逐条对齐的读端，两边各自有测试，同样的链接必须解出同样的东西。
public extension PendingNetPairingFile {
    static let urlScheme = "pendingnet"
    static let urlHost = "pair"

    /// 解析一条 `pendingnet://` 配对链接。首尾空白照吃 —— 链接是被粘进来的。
    static func decode(link: String, now: Date = Date()) throws -> Self {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == urlScheme,
              components.host?.lowercased() == urlHost,
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let items = components.queryItems
        else { throw PendingNetPairingError.invalidLink }

        var version: String?
        var payload: String?
        for item in items {
            switch item.name {
            case "v":
                guard version == nil else { throw PendingNetPairingError.invalidLink }
                version = item.value
            case "d":
                guard payload == nil else { throw PendingNetPairingError.invalidLink }
                payload = item.value
            default:
                throw PendingNetPairingError.invalidLink
            }
        }
        guard let version else { throw PendingNetPairingError.invalidLink }
        guard version == String(currentVersion) else {
            // 认得出「是条配对链接、只是版本更新」的，就报版本，别报「这不是链接」
            // —— 用户该去升级 App，不是去怀疑自己复制错了。
            guard let number = Int(version) else { throw PendingNetPairingError.invalidLink }
            throw PendingNetPairingError.unsupportedVersion(number)
        }
        guard let payload, let data = base64URLDecoded(payload) else {
            throw PendingNetPairingError.invalidLink
        }
        return try decode(data, now: now)
    }

    /// 粘贴框专用：一段文本，是链接就当链接、是 `.pdn` 原文就当文件内容。
    ///
    /// 用户手里可能是链接，也可能是把 `.pdn` 用文本编辑器打开后整段复制过来的
    /// —— 这个框存在的理由就是「一定管用」，多认一种形态是免费的。
    static func decode(pasted text: String, now: Date = Date()) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PendingNetPairingError.invalidLink }
        if trimmed.hasPrefix("{") {
            return try decode(Data(trimmed.utf8), now: now)
        }
        return try decode(link: trimmed, now: now)
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        // 标准 base64 的 + / 不属于 base64url，和 Go 侧一样当成畸形拒掉，
        // 而不是悄悄按另一套字母表解出别的东西。
        guard !value.isEmpty, !value.contains("+"), !value.contains("/") else { return nil }
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 链接里不带填充，路上被补了也照收：要严格的是载荷本身，不是它的填充。
        while encoded.hasSuffix("=") { encoded.removeLast() }
        let remainder = encoded.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: encoded)
    }
}
