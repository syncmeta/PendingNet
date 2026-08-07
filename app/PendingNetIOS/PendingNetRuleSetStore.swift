import Foundation
import SBTallyCore

/// 规则集（`.srs`）下载器。只在主 App 内联网——扩展始终以 `type: local`
/// 读取 App Group 里的二进制文件，自己从不发起下载（见
/// `PendingNetTunnelConfig.ruleSets(directory:)`）。
///
/// 文件名固定为 `<name>.srs`，名字与下载地址都取自
/// `PendingNetTunnelConfig.requiredRuleSets`——这是全项目唯一一份规则集
/// 名单，这里不再重复列一份，两处不一致的表现是 sing-box 启动时报
/// 「rule-set not found」。
@MainActor
final class PendingNetRuleSetStore: ObservableObject {
    /// 规则集全部就位且看上去确实是 `.srs`。`PendingNetTunnelController.start`
    /// 用它决定 `.bypassCN` 能不能直接开跑。
    @Published private(set) var isReady = false

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

        for source in PendingNetTunnelConfig.requiredRuleSets {
            let (temporary, response) = try await URLSession.shared.download(from: source.url)
            defer { try? FileManager.default.removeItem(at: temporary) }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PendingNetPairingError.serverRejected("规则集下载失败：\(source.name)")
            }
            // 只看状态码和大小是不够的：`raw.githubusercontent.com` 在大陆网络
            // 下不可达，中间设备或门户页返回 200 + 一段 HTML 是很现实的结果，
            // 它状态码正常、大小非零，照样会被原样装成 geoip-cn.srs，然后要到
            // sing-box 解析时才炸，而那时隧道已经起不来且没有任何诊断。
            // 认 `.srs` 的魔数（sing-box common/srs/binary.go 的 MagicBytes）。
            guard PendingNetTunnelConfig.looksLikeRuleSet(at: temporary.path) else {
                throw PendingNetPairingError.serverRejected(
                    "规则集内容不是有效的 .srs（可能被网络中间设备替换）：\(source.name)"
                )
            }

            // 原子替换，扩展随时可能在读；不能让它看到写了一半的文件。
            let destination = directory.appendingPathComponent("\(source.name).srs")
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
        isReady = Self.allPresent()
    }

    /// 同样按魔数判断，而不是「文件非空就当它有效」：上一轮可能落下过一个
    /// 被替换掉的 HTML 页面，那种文件非空但用不了，必须被认出来重下。
    private static func allPresent() -> Bool {
        guard let base = PendingNetTunnelPaths.container() else { return false }
        let directory = PendingNetTunnelPaths.ruleSetDirectory(in: base)
        return PendingNetTunnelConfig.requiredRuleSetNames.allSatisfy { name in
            PendingNetTunnelConfig.looksLikeRuleSet(
                at: directory.appendingPathComponent("\(name).srs").path
            )
        }
    }
}
