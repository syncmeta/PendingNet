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
    /// **全部**规则集都就位且看上去确实是 `.srs`。这是给设置页那个
    /// 「已就绪 / 未下载」标签看的整体状态，**不是**任何一档能不能开跑的
    /// 判据——那个判据按档位收窄，见 `isReady(for:)`。
    @Published private(set) var isReady = false

    init() {
        isReady = Self.allPresent()
    }

    /// 这一档位需要的规则集是否就位。`PendingNetTunnelController.start`
    /// 与分流选择器都用它，而不是用整体的 `isReady`：白名单只吃
    /// geoip-cn / geosite-cn，一份它用不到的 geosite-gfw 缺失不该把它挡掉。
    func isReady(for mode: PendingNetRouteMode) -> Bool {
        guard let directory = Self.directory() else { return false }
        return PendingNetTunnelConfig.ruleSetsPresent(mode: mode, directory: directory.path)
    }

    /// 补齐这一档位需要的规则集。已有有效文件的直接跳过，不重复下载——
    /// 切分流模式时调这个，而不是 `refresh()`。
    ///
    /// 只下这一档用得到的那几份：白名单不该因为 GFW 名单下不来而失败。
    func ensureAvailable(for mode: PendingNetRouteMode) async throws {
        try await download(
            tags: PendingNetTunnelConfig.ruleSetTags(mode: mode),
            force: false
        )
    }

    /// 无条件重新下载全部规则集。设置页那个「下载 / 重新下载」按钮走这里，
    /// 用户明确要求刷新时不跳过任何一份。
    func refresh() async throws {
        try await download(tags: PendingNetTunnelConfig.requiredRuleSetNames, force: true)
    }

    /// 下载指定的规则集。`force` 为 false 时跳过磁盘上已有的有效文件。
    ///
    /// 无论成功、失败还是中途抛错，`isReady` 都要照磁盘重算一遍：抛错时
    /// 前面几份可能已经落地了，让那个标签停在旧值只会误导。
    private func download(tags: [String], force: Bool) async throws {
        guard let directory = Self.directory() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        defer { isReady = Self.allPresent() }

        for source in PendingNetTunnelConfig.requiredRuleSets where tags.contains(source.name) {
            let destination = directory.appendingPathComponent("\(source.name).srs")
            if !force, PendingNetTunnelConfig.looksLikeRuleSet(at: destination.path) { continue }

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
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
    }

    /// 规则集目录，顺手把它建出来——下载和就绪判断都以它为准。
    private static func directory() -> URL? {
        guard let base = PendingNetTunnelPaths.container() else { return nil }
        try? PendingNetTunnelPaths.prepare(base: base)
        return PendingNetTunnelPaths.ruleSetDirectory(in: base)
    }

    /// 同样按魔数判断，而不是「文件非空就当它有效」：上一轮可能落下过一个
    /// 被替换掉的 HTML 页面，那种文件非空但用不了，必须被认出来重下。
    private static func allPresent() -> Bool {
        guard let directory = directory() else { return false }
        return PendingNetTunnelConfig.requiredRuleSetNames.allSatisfy { name in
            PendingNetTunnelConfig.looksLikeRuleSet(
                at: directory.appendingPathComponent("\(name).srs").path
            )
        }
    }
}
