import Foundation
import SBTallyCore

/// The geosite/geoip rule-sets 白名单/黑名单 route on.
///
/// They are cached as files next to the engine config and referenced as
/// `type: local` rule-sets. Remote rule-sets were the obvious alternative and
/// are not usable here: sing-box treats a failed initial download as fatal, so
/// one unreachable GitHub would leave the user with an engine that refuses to
/// start at all — including for 全局, which needs no rule-set.
struct PendingNetRouteRuleSets {
    /// 名字与下载地址取自 SBTallyCore 里那份**全项目唯一**的名单
    /// （`PendingNetTunnelConfig.requiredRuleSets`，iOS 侧用的是同一份）。
    /// 这里曾经另抄一份，两处只要有一边多/少一个名字，表现就是 sing-box
    /// 启动时报 rule-set not found。
    private static var sources: [PendingNetTunnelConfig.RuleSetSource] {
        PendingNetTunnelConfig.requiredRuleSets
    }

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) { self.directory = directory }

    private func url(forTag tag: String) -> URL? {
        guard let name = PendingNetProxyOnlyConfig.ruleSetFiles[tag] else { return nil }
        return directory.appendingPathComponent(name)
    }

    func isReady(for mode: PendingNetRouteMode) -> Bool {
        PendingNetTunnelConfig.ruleSetsPresent(mode: mode, directory: directory.path)
    }

    var availableModes: Set<PendingNetRouteMode> {
        Set([PendingNetRouteMode.whitelist, .blacklist].filter { isReady(for: $0) })
    }

    var availableRuleSetTags: Set<String> {
        Set(availableModes.flatMap { PendingNetTunnelConfig.ruleSetTags(mode: $0) })
    }

    /// Whether both list modes are cached. Individual mode availability is
    /// intentionally narrower; one failed download must not disable the other.
    var isReady: Bool {
        isReady(for: .whitelist) && isReady(for: .blacklist)
    }

    /// Path to hand the config builder once at least one list mode is usable.
    var configuredDirectory: String? { availableModes.isEmpty ? nil : directory.path }

    /// What the config builder needs, as one value — 目录和可用名单在这里配对，
    /// 调用方没有机会只给出其中一半。
    var configured: PendingNetProxyOnlyConfig.RuleSets? {
        configuredDirectory.map {
            PendingNetProxyOnlyConfig.RuleSets(directory: $0, availableTags: availableRuleSetTags)
        }
    }

    /// 每一份规则集此刻在不在本机。设置页按份显示，别让用户对着一个笼统的
    /// 「未下载」猜是哪一份没下来。
    var presence: [String: Bool] {
        Dictionary(uniqueKeysWithValues: PendingNetTunnelConfig.requiredRuleSetNames.map { name in
            (name, url(forTag: name).map {
                PendingNetTunnelConfig.looksLikeRuleSet(at: $0.path)
            } ?? false)
        })
    }

    /// Fetches whatever is missing, preferring the local proxy when the engine
    /// is up — a machine that needs these lists is usually one that can't reach
    /// GitHub without them. Best effort: returns the readiness afterwards.
    @discardableResult
    func download(throughLocalProxyPort port: Int?) async -> Bool {
        if isReady { return true }
        _ = await fetch(force: false, throughLocalProxyPort: port)
        return configuredDirectory != nil
    }

    /// 设置页那个「下载 / 重新下载」按钮走这里：用户明确要求刷新时不跳过
    /// 任何一份。返回 nil 表示全都拿到了，否则是给用户看的人话。
    func refresh(throughLocalProxyPort port: Int?) async -> String? {
        await fetch(force: true, throughLocalProxyPort: port)
    }

    /// 返回 nil 表示这一轮要拿的都拿到了，否则是第一条失败的人话。失败也
    /// 不中断——能落下一份是一份，白名单不该因为 GFW 名单下不来而拿不到。
    private func fetch(force: Bool, throughLocalProxyPort port: Int?) async -> String? {
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.connectionProxyDictionary = port.map {
            [
                kCFNetworkProxiesHTTPEnable: 1,
                kCFNetworkProxiesHTTPProxy: "127.0.0.1",
                kCFNetworkProxiesHTTPPort: $0,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": $0,
            ] as [AnyHashable: Any]
        } ?? [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var failure: String?
        for source in Self.sources {
            guard let destination = url(forTag: source.name) else { continue }
            if !force, PendingNetTunnelConfig.looksLikeRuleSet(at: destination.path) { continue }
            guard let (data, response) = try? await session.data(from: source.url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                failure = failure ?? "规则集下载失败：\(source.name)"
                continue
            }
            // .srs files start with "SRS" — an HTML error page must not be
            // written to the cache and then fail config validation.
            guard data.count > 64, data.prefix(3) == Data("SRS".utf8) else {
                failure = failure ?? "规则集内容不是有效的 .srs（可能被网络中间设备替换）：\(source.name)"
                continue
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                failure = failure ?? "规则集写入失败：\(source.name)"
            }
        }
        return failure
    }
}
