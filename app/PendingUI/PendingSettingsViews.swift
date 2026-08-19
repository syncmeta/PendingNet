import SBTallyCore
import SwiftUI

/// 两端设置页共用的三张卡：端口 / 规则集 / 更新。
///
/// 连接页已经这么做过一轮（见 PendingConnectionViews）。设置页跟上：同一套
/// 内容、同一个顺序、同一种版式，两端只在**确实不适用**的地方少几行——iOS
/// 不走 Sparkle，所以更新卡上那两个自动更新开关和「检查更新…」按钮在手机上
/// 没有对应物，其余一字不差。
///
/// 各端往里塞的数据来源不同（macOS 是自己跑的 sing-box，iOS 是 Packet Tunnel
/// 扩展里的内核），但**语义相同**：端口就是本机混合入站的端口，局域网开关
/// 就是把它从 127.0.0.1 换成 0.0.0.0。

// MARK: - 端口

/// 端口 + 允许局域网访问。
///
/// 校验、错误文案、存档全部来自 SBTallyCore 的 `PendingNetLocalInbound`，
/// 这张卡只负责把话说出来。
struct PendingLocalInboundCard: View {
    /// 现在监听在哪（127.0.0.1 或 0.0.0.0）。
    let listenAddress: String
    let port: Int
    let allowsLAN: Bool
    /// 本端另有别用、不能被抢走的端口。macOS 是 sing-box 控制端口 29090；
    /// iOS 的隧道没有这种端口，传 nil。
    var reservedPort: Int?
    /// 返回 nil 表示成功，否则是给用户看的人话。
    let save: (Int, Bool) async -> String?

    @State private var portField = ""
    @State private var saving = false
    @EnvironmentObject private var toast: PendingToastCenter

    var body: some View {
        PendingSectionCard("端口") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // verbatim: 地址和端口都是标识符，别被本地化成 "2,080"
                    Text(verbatim: "\(listenAddress) :")
                        .font(PendingNetTheme.Fonts.body.monospaced())
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    portTextField
                    Button("保存") { commit() }
                        .buttonStyle(PendingQuietButtonStyle())
                        .disabled(saving || portField == String(port))
                    if saving { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }

                Toggle("允许局域网访问", isOn: Binding(
                    get: { allowsLAN },
                    set: { commit(allowLAN: $0) }
                ))
                .toggleStyle(.switch)
                .tint(PendingNetTheme.Palette.accent)
                .font(PendingNetTheme.Fonts.body)
                .foregroundStyle(PendingNetTheme.Palette.ink)
                .disabled(saving)
            }
        }
        .task { portField = String(port) }
        // 保存失败时端口会被调用方退回原值，输入框要跟着退回去，否则界面上
        // 停着一个根本没生效的数字。
        .onChange(of: port) { _, next in
            if !saving { portField = String(next) }
        }
    }

    private var portTextField: some View {
        let field = TextField("", text: $portField)
            .textFieldStyle(.roundedBorder)
            .font(PendingNetTheme.Fonts.body.monospaced())
            .frame(width: 92)
            .onSubmit { commit() }
        #if os(iOS)
            return field
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            return field
        #endif
    }

    /// 校验 → 交给调用方落地。四种不合格分别说清楚，绝不假装保存成功。
    private func commit(allowLAN: Bool? = nil) {
        let nextLAN = allowLAN ?? allowsLAN
        let port: Int
        do {
            port = try PendingNetLocalInbound.resolvePort(
                from: portField,
                current: self.port,
                // 探的是这次真要监听的那个地址：开着局域网访问时要占的是
                // 0.0.0.0，只探 127.0.0.1 会漏掉冲突。
                listenAddress: PendingNetLocalInbound(allowsLAN: nextLAN).listenAddress,
                reservedPort: reservedPort
            )
        } catch {
            toast.show(error.localizedDescription)
            return
        }
        saving = true
        Task {
            let failure = await save(port, nextLAN)
            saving = false
            if let failure { toast.show(failure) }
            // 成功就把输入框对齐到刚存下的那个端口；失败**不动**它——调用方
            // 已经把设置退回原值了，此刻把用户刚敲的数字也抹掉，他连改错了
            // 什么都看不见。（不能写 `String(self.port)`：这个 View 实例的
            // `port` 还是这一帧渲染时的旧值。）
            if failure == nil { portField = String(port) }
        }
    }
}

// MARK: - 规则集

/// 一份规则集在本机的状态。
struct PendingRuleSetItem: Identifiable {
    let name: String
    let ready: Bool

    var id: String { name }

    /// 给人看的名字。配置里的 tag 是 geosite-cn 这种，摊在设置页上没人看得懂。
    var title: String {
        switch name {
        case "geoip-cn": "国内 IP 段"
        case "geosite-cn": "国内域名"
        case "geosite-gfw": "被墙域名"
        default: name
        }
    }
}

/// 规则集：白名单 / 黑名单靠它分流。两端读的是各自的缓存目录，展示一模一样。
struct PendingRuleSetCard: View {
    let items: [PendingRuleSetItem]
    /// 返回 nil 表示成功，否则是给用户看的人话。
    let refresh: () async -> String?

    @State private var refreshing = false
    @EnvironmentObject private var toast: PendingToastCenter

    private var isReady: Bool { !items.isEmpty && items.allSatisfy(\.ready) }

    var body: some View {
        PendingSectionCard("规则集") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PendingStatusPill(
                        text: isReady ? "已就绪" : "未下载",
                        kind: isReady ? .success : .neutral
                    )
                    Spacer(minLength: 0)
                }

                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .font(PendingNetTheme.Fonts.body)
                            .foregroundStyle(PendingNetTheme.Palette.ink)
                        // verbatim: tag 是配置里的标识符
                        Text(verbatim: item.name)
                            .font(PendingNetTheme.Fonts.caption.monospaced())
                            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        Spacer()
                        Text(item.ready ? "已就绪" : "缺失")
                            .font(PendingNetTheme.Fonts.caption)
                            .foregroundStyle(item.ready
                                ? PendingNetTheme.Palette.success
                                : PendingNetTheme.Palette.inkMuted)
                    }
                }

                Button {
                    Task {
                        refreshing = true
                        let failure = await refresh()
                        refreshing = false
                        // 下好了不报喜：上面每一份的「已就绪 / 缺失」和那颗
                        // 状态药丸自己会翻，只有失败才说话。
                        if let failure { toast.show(failure) }
                    }
                } label: {
                    if refreshing {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                        }
                    } else {
                        Text(isReady ? "重新下载" : "下载")
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(refreshing)
            }
        }
    }
}

// MARK: - 更新

/// 更新卡。版本行两端相同；`trailing` 与 `extra` 留给平台专属的东西——
/// macOS 放 Sparkle 的「检查更新…」和两个自动更新开关，iOS 两处都空着。
/// iOS 上**不给**一个点了没反应的检查按钮：那种假控件比没有更糟。
struct PendingUpdateCard<Trailing: View, Extra: View>: View {
    let version: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let extra: Extra

    init(
        version: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.version = version
        self.trailing = trailing()
        self.extra = extra()
    }

    var body: some View {
        PendingSectionCard("更新") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // verbatim: 版本号是标识符，不是数量
                    Text(verbatim: "当前版本 \(version)")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    trailing
                }
                extra
            }
            .font(PendingNetTheme.Fonts.body)
            .foregroundStyle(PendingNetTheme.Palette.ink)
        }
    }
}
