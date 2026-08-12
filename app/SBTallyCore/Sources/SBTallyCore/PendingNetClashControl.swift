import Foundation

/// sing-box 的 Clash 控制口：怎么找到它，以及一份配置到底认哪几档路由模式。
///
/// 两边都要用这套判断，所以放在这里而不是各写一份：app 直连自己拉起的那份
/// 引擎，特权助手连它用 root 另起的那份（配置在 `/usr/local/etc/sbtally`）。
public enum PendingNetClashControl {
    /// 配置里由 `clash_mode` 规则声明出来的那些档。
    ///
    /// 必须照配置核一遍，因为 Clash API 对**没声明**的档照样回 204：切过去以后
    /// 引擎其实还按老规矩走，界面却已经把新的那颗药丸点亮了——显示和实际不一致
    /// 比切不动更糟。
    public static func declaredModes(in configData: Data) -> Set<PendingNetRouteMode> {
        guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let route = root["route"] as? [String: Any],
              let rules = route["rules"] as? [[String: Any]] else { return [] }
        return Set(rules.compactMap { rule in
            (rule["clash_mode"] as? String).flatMap(PendingNetRouteMode.clashNamed)
        })
    }
}

/// 一份 sing-box 配置里 `experimental.clash_api` 指的那个控制口。
public struct PendingNetClashEndpoint: Sendable, Equatable {
    /// `external_controller` 的原样值，形如 `127.0.0.1:9090`。
    public let controller: String
    /// `secret`，没设就是空串（那时不发 Authorization 头）。
    public let secret: String

    public init(controller: String, secret: String) {
        self.controller = controller
        self.secret = secret
    }

    /// 从 sing-box 配置里读出控制口；没有 `clash_api` 一节就是 nil。
    public init?(configData: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let experimental = root["experimental"] as? [String: Any],
              let clashAPI = experimental["clash_api"] as? [String: Any],
              let controller = clashAPI["external_controller"] as? String,
              !controller.isEmpty else { return nil }
        self.init(controller: controller, secret: clashAPI["secret"] as? String ?? "")
    }

    /// 控制口上某条路径的 URL —— 只认本机，别的一律 nil。
    ///
    /// 这个口能改整台机器的路由，请求还带着 secret；配置万一写成对外地址，
    /// 宁可什么都不发，也不能把 root 引擎的钥匙送到别人机器上。
    public func url(path: String) -> URL? {
        guard let url = URL(string: "http://\(controller)/\(path)"),
              url.scheme == "http",
              url.host == "127.0.0.1" || url.host == "::1" || url.host == "localhost"
        else { return nil }
        return url
    }
}

extension PendingNetRouteMode {
    /// Clash API 与配置里 `clash_mode` 用的写法。
    public var clashName: String {
        switch self {
        case .global: "Global"
        case .whitelist: "Whitelist"
        case .blacklist: "Blacklist"
        }
    }

    /// 认 Clash 那边的写法。大小写不敏感 —— 回读 `/configs` 拿到的值不保证和
    /// 发下去的那个字一模一样，而这里判的是「是不是同一档」。
    public static func clashNamed(_ name: String) -> PendingNetRouteMode? {
        allCases.first { $0.clashName.caseInsensitiveCompare(name) == .orderedSame }
    }
}
