import Foundation

/// selector 成员在界面上叫什么。两端共用这一份，Mac 和 iPhone 上的协议
/// 选项才会一字不差。
///
/// 成员 tag 形如 `<selectorTag>-<协议 id>`，外加一个 `<selectorTag>-mix`
/// ——那是内核的 urltest 自动选路。界面上它就叫「混合」：用户要选的是
/// 「走哪条」，不是去理解 urltest 是什么。
public enum PendingNetOutboundNaming {
    public static let mixSuffix = "mix"
    public static let mixTitle = "混合"

    public static func title(forMemberTag tag: String, selectorTag: String?) -> String {
        var suffix = tag
        if let selectorTag, tag.hasPrefix(selectorTag + "-") {
            suffix = String(tag.dropFirst(selectorTag.count + 1))
        }
        let lowered = suffix.lowercased()
        if lowered == mixSuffix { return mixTitle }
        // 认关键字而不是精确等于：协议 id 由 VPS 下发（现在是 reality / hy2），
        // 哪天多一个变体也不至于在界面上冒出一串裸 tag。
        if lowered.contains("reality") || lowered.contains("vless") { return "Reality" }
        if lowered.contains("hysteria") || lowered.hasPrefix("hy") { return "Hysteria2" }
        return suffix
    }
}
