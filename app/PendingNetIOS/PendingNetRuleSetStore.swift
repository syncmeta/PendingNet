import Foundation
import SBTallyCore

/// 规则集（`.srs`）下载器。只在主 App 内联网——扩展始终以 `type: local`
/// 读取 App Group 里的二进制文件，自己从不发起下载（见
/// `PendingNetTunnelConfig.ruleSets(directory:)`）。
///
/// 文件名固定为 `<name>.srs`，`<name>` 取自
/// `PendingNetTunnelConfig.requiredRuleSetNames`——这是全项目唯一一份
/// 规则集名单，这里不再重复列一份，两处不一致的表现是 sing-box 启动时
/// 报「rule-set not found」。
@MainActor
final class PendingNetRuleSetStore: ObservableObject {
    @Published private(set) var isReady = false

    private static let sources: [String: URL] = [
        "geoip-cn": URL(
            string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
        )!,
        "geosite-cn": URL(
            string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
        )!,
    ]

    init() {
        isReady = Self.allPresent()
    }

    /// 已有有效文件时直接返回，不重复下载。切分流模式到 `.bypassCN` 时调
    /// 这个，而不是 `refresh()`——已经在用的规则集没有理由每次都重下。
    func ensureAvailable() async throws {
        if Self.allPresent() {
            isReady = true
            return
        }
        try await refresh()
    }

    /// 无条件重新下载全部规则集。
    func refresh() async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        let directory = PendingNetTunnelPaths.ruleSetDirectory(in: base)

        for name in PendingNetTunnelConfig.requiredRuleSetNames {
            guard let source = Self.sources[name] else {
                throw PendingNetPairingError.serverRejected("未知规则集：\(name)")
            }
            let (temporary, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: temporary) }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PendingNetPairingError.serverRejected("规则集下载失败：\(name)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]
                as? Int) ?? 0
            // 空文件会让 sing-box 启动时报 `parse rule-set[0]: EOF`，宁可保留
            // 旧文件（如果有）也不能让空文件落地。
            guard size > 0 else {
                throw PendingNetPairingError.serverRejected("规则集内容为空：\(name)")
            }

            // 原子替换，扩展随时可能在读；不能让它看到写了一半的文件。
            let destination = directory.appendingPathComponent("\(name).srs")
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
        isReady = Self.allPresent()
    }

    private static func allPresent() -> Bool {
        guard let base = PendingNetTunnelPaths.container() else { return false }
        let directory = PendingNetTunnelPaths.ruleSetDirectory(in: base)
        return PendingNetTunnelConfig.requiredRuleSetNames.allSatisfy { name in
            let path = directory.appendingPathComponent("\(name).srs").path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return size > 0
        }
    }
}
