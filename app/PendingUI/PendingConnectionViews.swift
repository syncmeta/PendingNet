import SBTallyCore
import SwiftUI

/// 连接页只认这三个档位。展示名放在共用 UI 里，避免两端再次各写一套文案。
extension PendingNetRouteMode {
    var pendingTitle: String {
        switch self {
        case .global: "全局"
        case .whitelist: "白名单"
        case .blacklist: "黑名单"
        }
    }
}

/// 两端连接页共用的卡片外壳。卡内放什么仍由各端组合，平台专属功能不会混进来。
struct PendingConnectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 状态药丸与连接动作。输入只有显示状态和回调；授权、隧道等语义由调用端处理。
struct PendingConnectionHeader: View {
    enum Action {
        case toggle(isOn: Bool, enabled: Bool = true)
        case button(title: String, enabled: Bool = true)
    }

    let statusText: String
    let statusKind: PendingStatusPill.Kind
    var isBusy = false
    let action: Action
    let onAction: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PendingStatusPill(text: statusText, kind: statusKind)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            switch action {
            case .toggle(let isOn, let enabled):
                Toggle("连接", isOn: Binding(
                    get: { isOn },
                    set: onAction
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(PendingNetTheme.Palette.accent)
                .disabled(!enabled)
            case .button(let title, let enabled):
                Button(title) { onAction(true) }
                    .buttonStyle(PendingPrimaryButtonStyle())
                    .disabled(!enabled)
            }
        }
    }
}

/// 固定文案的三档路由选择器。业务层只负责把档位映射到各自的状态模型。
struct PendingRouteModePicker: View {
    let selection: PendingNetRouteMode?
    var isEnabled = true
    let onSelect: (PendingNetRouteMode) -> Void

    var body: some View {
        PendingPillPicker(
            options: PendingNetRouteMode.allCases.map { .init($0, $0.pendingTitle) },
            selection: selection,
            select: onSelect
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
    }
}

/// VPS 列表本体：选中标记、地址、切换中状态、点按切换与详情入口都在这里共用。
struct PendingVPSList: View {
    let items: [PairedVPSRecord]
    let selectedID: String?
    var switchingID: String? = nil
    /// 这台设备上没有访问凭据的那几台。
    ///
    /// VPS 记录走 iCloud 键值存储，访问凭据走 iCloud 钥匙串——两条链是分开的，
    /// 记录到了而凭据没到是常态（换了新设备、iCloud 钥匙串没开、还没同步完）。
    /// 这几行必须一眼看得出来是打不开的：以前它们和能用的长得一模一样，还能
    /// 打上勾，点下去才在页面底部弹一条红字，用户对着一排看着能用的死条目
    /// 完全无从下手。
    var unpairedIDs: Set<String> = []
    /// 每台 VPS 一个延迟数（`serverID -> 结果`）。语义只有一种：本机到这台
    /// VPS 代理入口的 TCP 握手往返时间，见 `PendingNetLatencyTarget`。
    var latencies: [String: PendingNetLatencyOutcome] = [:]
    var detailID: Binding<String?>? = nil
    let onSelect: (String) -> Void
    let onShowDetails: (String) -> Void
    var detailPopover: ((PairedVPSRecord) -> AnyView)? = nil

    var body: some View {
        if items.isEmpty {
            Text("还没有配对 VPS，导入 .pdn 后这里会列出你的服务器。")
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(PendingNetTheme.Palette.hairline)
                    }
                    row(item)
                }
            }
            .background(PendingNetTheme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
            }
        }
    }

    private func row(_ item: PairedVPSRecord) -> some View {
        let selected = item.id == selectedID
        let switching = item.id == switchingID
        let unpaired = unpairedIDs.contains(item.id)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .opacity(selected && !unpaired ? 1 : 0)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                // verbatim: 地址是标识符，不能被本地化
                Text(verbatim: item.address)
                    .font(selected && !unpaired
                        ? PendingNetTheme.Fonts.bodyEmphasized.monospaced()
                        : PendingNetTheme.Fonts.body.monospaced())
                    .foregroundStyle(unpaired
                        ? PendingNetTheme.Palette.inkMuted
                        : PendingNetTheme.Palette.ink)
                if unpaired {
                    Text("这台设备还没配对，导入这台 VPS 的 .pdn 就能用")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                } else if let reason = latencies[item.id]?.failureText {
                    // 「不通」两个字说不清是被拒还是解析不了，原因就摆在这行下面。
                    Text(reason)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if switching {
                ProgressView().controlSize(.small)
            } else if unpaired {
                Text("未配对")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PendingNetTheme.Palette.canvas)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
                    }
            } else {
                HStack(spacing: 10) {
                    latencyLabel(item)
                    detailButton(item)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 没凭据的行点了也只会失败，不给点——「未配对」那个标记已经把该做的事
        // 说清楚了，让它可点只会换来一条红字。
        .onTapGesture {
            guard !selected, !unpaired else { return }
            onSelect(item.id)
        }
    }

    /// 延迟贴在行右边：测量中转圈，测完就是「延迟 42 ms」，不通就是「不通」
    /// （原因在地址那行下面）。
    @ViewBuilder
    private func latencyLabel(_ item: PairedVPSRecord) -> some View {
        switch latencies[item.id] {
        case .measuring:
            ProgressView().controlSize(.small)
        case .some(let outcome):
            if let text = outcome.rowText {
                // verbatim: 毫秒数是测量值，不该被本地化成千分位
                Text(verbatim: text)
                    .font(PendingNetTheme.Fonts.caption.monospaced())
                    .foregroundStyle(outcome.failureText == nil
                        ? PendingNetTheme.Palette.inkMuted
                        : PendingNetTheme.Palette.danger)
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func detailButton(_ item: PairedVPSRecord) -> some View {
        if let detailID, let detailPopover {
            Button("详情") { onShowDetails(item.id) }
                .buttonStyle(.plain)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .popover(isPresented: Binding(
                    get: { detailID.wrappedValue == item.id },
                    set: { if !$0 { detailID.wrappedValue = nil } }
                ), arrowEdge: .bottom) {
                    detailPopover(item)
                }
        } else {
            Button("详情") { onShowDetails(item.id) }
                .buttonStyle(.plain)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.accent)
        }
    }
}

/// 详情内容共用，承载方式仍遵循平台习惯：macOS popover，iOS sheet。
struct PendingVPSDetails: View {
    enum NameStyle {
        case heading
        case labeledRow
    }

    let server: PairedVPSRecord
    let nameStyle: NameStyle
    let spacing: CGFloat
    /// 这台 VPS 的延迟。详情是唯一说得下「测的到底是哪个端点」的地方。
    var latency: PendingNetLatencyOutcome? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            switch nameStyle {
            case .heading:
                Text(server.name)
                    .font(PendingNetTheme.Fonts.bodyEmphasized)
                    .foregroundStyle(PendingNetTheme.Palette.ink)
            case .labeledRow:
                detailRow("名称", server.name)
            }

            detailRow("地址", server.address, monospaced: true)
            if let port = server.controlPort {
                // verbatim: 端口是标识符不是数量（否则 7443 会被显示成 "7,443"）
                detailRow("端口", port, monospaced: true)
            }
            if let protocols = server.nodeProtocols, !protocols.isEmpty {
                detailRow("支持的协议", protocols.joined(separator: " · "))
            }
            latencyBlock
        }
    }

    /// 延迟单独成块，不塞进 detailRow：右边那一栏放不下「测的是哪个端点」
    /// 这句话，而这句话正是这个数字有没有意义的关键。
    @ViewBuilder
    private var latencyBlock: some View {
        switch latency {
        case .measuring:
            detailRow("延迟", "正在测…")
        case .ok(let milliseconds, let target):
            VStack(alignment: .leading, spacing: 4) {
                detailRow("延迟", "\(milliseconds) ms", monospaced: true)
                Text(target.explanation)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                detailRow("延迟", "不通")
                Text(reason)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .none:
            EmptyView()
        }
    }

    private func detailRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            Spacer()
            // verbatim: 地址/端口都是标识符，不能被本地化成千分位数字
            Text(verbatim: value)
                .font(monospaced
                    ? PendingNetTheme.Fonts.caption.monospaced()
                    : PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}
