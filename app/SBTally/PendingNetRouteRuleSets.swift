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
    private static let sources: [String: String] = [
        "geosite-cn":
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "geoip-cn":
            "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "geosite-noncn":
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "geosite-gfw":
            "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs",
    ]

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) { self.directory = directory }

    private func url(forTag tag: String) -> URL? {
        guard let name = PendingNetProxyOnlyConfig.ruleSetFiles[tag] else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Whether every rule-set is cached, i.e. whether the engine config may
    /// declare 白名单/黑名单 at all.
    var isReady: Bool {
        PendingNetProxyOnlyConfig.ruleSetFiles.keys.allSatisfy { tag in
            guard let url = url(forTag: tag),
                  let size = try? fileManager
                      .attributesOfItem(atPath: url.path)[.size] as? Int else { return false }
            return size > 0
        }
    }

    /// Path to hand the config builder, or nil while the cache is incomplete.
    var configuredDirectory: String? { isReady ? directory.path : nil }

    /// Fetches whatever is missing, preferring the local proxy when the engine
    /// is up — a machine that needs these lists is usually one that can't reach
    /// GitHub without them. Best effort: returns the readiness afterwards.
    @discardableResult
    func download(throughLocalProxyPort port: Int?) async -> Bool {
        if isReady { return true }
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

        for (tag, source) in Self.sources {
            guard let destination = url(forTag: tag),
                  !fileManager.fileExists(atPath: destination.path),
                  let remote = URL(string: source) else { continue }
            guard let (data, response) = try? await session.data(from: remote),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 64,
                  // .srs files start with "SRS" — an HTML error page must not be
                  // written to the cache and then fail config validation.
                  data.prefix(3) == Data("SRS".utf8) else { continue }
            try? data.write(to: destination, options: .atomic)
        }
        return isReady
    }
}
