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
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .opacity(selected ? 1 : 0)
                .frame(width: 14)
            // verbatim: 地址是标识符，不能被本地化
            Text(verbatim: item.address)
                .font(selected
                    ? PendingNetTheme.Fonts.bodyEmphasized.monospaced()
                    : PendingNetTheme.Fonts.body.monospaced())
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            if switching {
                ProgressView().controlSize(.small)
            } else {
                detailButton(item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            onSelect(item.id)
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
