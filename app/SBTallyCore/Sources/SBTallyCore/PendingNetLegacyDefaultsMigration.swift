import Foundation

/// 把 0.3.18 及以前那个 bundle id 下的本地设置搬到现在这个域。
///
/// macOS 的 `UserDefaults.standard` 挂在 bundle id 命名的域上。2026-08-08 把
/// `net.pending.PendingNet` 归一成 `com.pendingname.pendingnet` 之后，新版一启动
/// 读到的是一个全空的域 —— 已配对的 VPS、代理端口、是否允许局域网，全没了，看上去
/// 就像升级把用户的设置抹了。
///
/// 三条规矩：
///  1. **只读旧域，绝不写它。** 用户装回旧版还得照常能用。
///  2. **搬完打标记，只搬一次。** 否则用户在新版里把某项改回默认，下次启动又被
///     旧值顶回来。
///  3. **新域已有值就不覆盖。** 标记之外的第二道保险。
///
/// 已配对 VPS 不在这里落盘：它归 `PairedVPSStore` 管，要和 iCloud 那边合并，所以
/// 这里只把旧存档解出来交给调用方喂给 `adoptLegacy`。
public enum PendingNetLegacyDefaultsMigration {
    /// 旧版 macOS app 的 bundle id，也就是它那个 `UserDefaults` 域的名字。
    public static let legacyDomain = "net.pending.PendingNet"

    /// 搬完的标记，写在**新**域里。
    public static let completionKey = "pendingnet.migrated-from-legacy-bundle-id.v1"

    /// 逐个照搬的标量设置。
    ///
    /// 只列用户真正设过的东西。窗口位置、Sparkle 的上次检查时间这类由框架自己
    /// 维护的键故意不搬 —— 它们在新域里重新长出来就行，搬过去只会带进陈旧状态。
    ///
    /// `PendingNetHelperWasEnabled` 是个例外，值得单说：它记的是「用户曾经批准过
    /// 后台助手」。搬过去，新版第一次启动就会把**新的**助手注册上去，于是它立刻
    /// 出现在「登录项与扩展」里等着被打开；不搬的话，用户得先去点一次「授权」才
    /// 看得到它。改名换的是助手的身份，不是用户的意愿，所以搬。
    public static let scalarKeys = [
        "pendingnet.route-mode",
        "pendingnet.local-proxy-port",
        "pendingnet.allow-lan",
        "PendingNetHelperWasEnabled",
    ]

    /// 跑一次迁移，返回旧域里那批已配对 VPS（交给 `PairedVPSStore.adoptLegacy`）。
    /// 已经搬过、或者旧域根本不存在，返回空数组。
    @discardableResult
    public static func run(
        from legacy: UserDefaults? = UserDefaults(suiteName: legacyDomain),
        into target: UserDefaults = .standard
    ) -> [PairedVPSRecord] {
        guard !target.bool(forKey: completionKey) else { return [] }
        defer { target.set(true, forKey: completionKey) }
        guard let legacy else { return [] }

        for key in scalarKeys {
            guard target.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            target.set(value, forKey: key)
        }

        guard let data = legacy.data(forKey: PairedVPSStore.defaultLocalKey),
              let records = try? JSONDecoder().decode([PairedVPSRecord].self, from: data) else {
            return []
        }
        return records
    }
}
