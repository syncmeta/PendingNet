import NetworkExtension
import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

/// 连接页。版式对齐 macOS 定稿：**一张卡**，卡里从上到下是
/// 开关 → 路由 → VPS 列表 → 协议，药丸左边不再有小标题。
///
/// macOS 的「接管方式」（仅端口 / 系统代理 / TUN）在 iOS 上没有对应物——
/// 系统只给 Packet Tunnel 这一条路，所以那一排在这里不存在，而不是做成
/// 一排点不动的药丸。
struct PendingNetIOSHomeView: View {
    @EnvironmentObject private var controller: PendingNetIOSController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImporter = false
    @State private var showingLog = false
    @State private var testingOutbounds = false
    @State private var switchingOutbound: String?
    @State private var switchingRouteMode = false
    @State private var detailServerID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                connectionCard
                    .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("连接")
            .toolbarBackground(PendingNetTheme.Palette.canvas, for: .navigationBar)
            .tint(PendingNetTheme.Palette.accent)
            .toolbar {
                // 诊断入口，刻意做得不起眼：只是个图标按钮，不占正文空间。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLog = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .accessibilityLabel("隧道日志")
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "pdn") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await controller.importAndEnroll(url: url) }
            case .failure(let error):
                controller.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingLog) {
            PendingNetTunnelLogView()
        }
        .sheet(item: Binding(
            get: { controller.servers.first { $0.serverID == detailServerID } },
            set: { if $0 == nil { detailServerID = nil } }
        )) { server in
            PendingNetServerDetailSheet(server: server)
        }
        .task { await controller.refreshNodeProfile() }
        .task { await controller.tunnel.load() }
        // selector tag 只取决于 serverID，节点资料一到就能算出来；隧道是否
        // 已连接不影响这里，控制通道自己会跟着隧道状态开合。
        .task(id: controller.nodeProfile?.serverID) {
            guard let server = controller.server, let profile = controller.nodeProfile else { return }
            controller.tunnel.bindSelector(profile: profile, serverName: server.name)
        }
        // 退到后台就把分组流拆掉——扩展只有约 50MB 额度，没人看的时候不该
        // 让它继续往一个没人读的 socket 里写。
        .onChange(of: scenePhase) { _, phase in
            controller.tunnel.setForeground(phase == .active)
        }
        // 隧道一旦不在位，两个「进行中」标志必须无条件归位。它们是 @State，
        // 活得比选择器的显示条件长：靠 RPC 自己返回来清是不够的（挂住的
        // 调用可能永远不返回），那样重连之后每一行都会是灰的、且没有任何
        // 用户可见的恢复路径。
        .onChange(of: controller.tunnel.isTunnelLive) { _, live in
            guard !live else { return }
            testingOutbounds = false
            switchingOutbound = nil
        }
    }

    // MARK: - 一张卡，一种控件

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            routeModePills

            vpsList

            if controller.tunnel.isTunnelLive, !controller.tunnel.outboundMembers.isEmpty {
                outboundPills
            }

            if let message = controller.message {
                messageBanner(message, kind: .success)
            }
            if let error = controller.errorMessage {
                messageBanner(error, kind: .danger)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PendingNetTheme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
        }
    }

    /// 状态药丸 + 原来的滑动开关。开关是「连接/断开」这一个动作，不是多选一，
    /// 所以它不做成药丸——这一点和 macOS 定稿一致。
    private var header: some View {
        HStack(spacing: 10) {
            PendingStatusPill(text: statusText, kind: statusKind)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("连接", isOn: Binding(
                get: { isConnected },
                set: { on in Task { await setConnected(on) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(PendingNetTheme.Palette.accent)
            .disabled(isBusy || controller.server == nil || controller.nodeProfile == nil)
        }
    }

    private func setConnected(_ on: Bool) async {
        guard let server = controller.server, let profile = controller.nodeProfile else { return }
        if !on {
            await controller.tunnel.stop()
            return
        }
        do {
            controller.errorMessage = nil
            try await controller.tunnel.start(
                profile: profile,
                serverName: server.name,
                serverID: profile.serverID
            )
            // 规则集不可用时 start 会降级到全局代理而不是失败；降级必须让
            // 用户看见，否则界面上的「绕过大陆」会悄悄变成「全局代理」。
            if let notice = controller.tunnel.degradeNotice {
                controller.errorMessage = notice
                controller.tunnel.degradeNotice = nil
            }
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 路由

    /// 三档分流模式。切换只做两件事：落 `routeMode`（`.bypassCN` 之前先
    /// 确保规则集在），隧道在位再 `reload` 把新配置真正推给扩展。两者都
    /// 不重启隧道进程本身——`.bypassCN`/`.direct` 的差别只在 sing-box 的
    /// route/dns 段，`reload` 走的是已经建立的 `sendProviderMessage`
    /// 通道。未连接时只落地 `routeMode`，下一次 `start` 会带着它生效。
    private var routeModePills: some View {
        PendingPillPicker(
            options: PendingNetRouteMode.allCases.map { .init($0, routeModeTitle($0)) },
            selection: controller.tunnel.routeMode
        ) { mode in
            guard let server = controller.server, let profile = controller.nodeProfile else { return }
            Task { await switchRouteMode(to: mode, profile: profile, serverName: server.name) }
        }
        .disabled(switchingRouteMode)
        .opacity(switchingRouteMode ? 0.6 : 1)
    }

    /// 切换分流模式的完整流程，含降级。
    ///
    /// `.bypassCN` 需要规则集：拿不到就不切——保持在原模式（多数情况下是
    /// 已经在用的全局代理），并提示用户，绝不能让隧道因为规则集缺失/损坏
    /// 而起不来。真正应用新模式（落地 `routeMode` + 已连接时 `reload`）统一
    /// 走 `applyRouteMode`，成功与「降级回退」共用同一条路径。
    private func switchRouteMode(
        to mode: PendingNetRouteMode,
        profile: PendingNetNodeProfile,
        serverName: String
    ) async {
        guard mode != controller.tunnel.routeMode else { return }
        let previous = controller.tunnel.routeMode
        switchingRouteMode = true
        defer { switchingRouteMode = false }
        controller.errorMessage = nil
        controller.message = nil

        if mode == .bypassCN {
            do {
                try await controller.ruleSetStore.ensureAvailable()
            } catch {
                controller.errorMessage = "规则集不可用，已保持全局代理：\(error.localizedDescription)"
                // 降级：确保隧道（如果在位）确实跑在全局代理上，而不是停在
                // 「用户点了绕过大陆，但没人知道最终生效的是哪个模式」这种
                // 界面选中项和隧道实际配置对不上的状态。
                if previous != .global {
                    _ = await applyRouteMode(.global, previous: previous, profile: profile, serverName: serverName)
                }
                return
            }
        }

        if await applyRouteMode(mode, previous: previous, profile: profile, serverName: serverName) {
            controller.message = "已切换到「\(routeModeTitle(mode))」"
        }
    }

    /// 落地 `routeMode` 并在隧道在位时 `reload`。`reload` 现在会一直等到
    /// 扩展真正确认收到新配置才返回——不再是「消息发出去就算数」，所以这里
    /// 失败即代表新配置没有生效，必须把 `routeMode` 退回原值，不能让持久化
    /// 状态和隧道里实际跑着的配置对不上。
    private func applyRouteMode(
        _ mode: PendingNetRouteMode,
        previous: PendingNetRouteMode,
        profile: PendingNetNodeProfile,
        serverName: String
    ) async -> Bool {
        controller.tunnel.setRouteMode(mode, profile: profile, serverName: serverName)
        guard controller.tunnel.isTunnelLive else { return true }
        do {
            try await controller.tunnel.reload(profile: profile, serverName: serverName)
            return true
        } catch {
            controller.tunnel.setRouteMode(previous, profile: profile, serverName: serverName)
            controller.errorMessage = "切换分流模式失败，已回退：\(error.localizedDescription)"
            return false
        }
    }

    private func routeModeTitle(_ mode: PendingNetRouteMode) -> String {
        switch mode {
        case .global: "全局代理"
        case .bypassCN: "绕过大陆"
        case .direct: "全局直连"
        }
    }

    // MARK: - VPS：竖排列表，选中的那行前面打勾

    private var vpsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    if controller.working {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在配对…")
                        }
                    } else {
                        Label("导入 .pdn", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(controller.working)
            }

            if controller.servers.isEmpty {
                Text("还没有配对 VPS，导入 .pdn 后这里会列出你的服务器。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(controller.servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider().overlay(PendingNetTheme.Palette.hairline) }
                        vpsRow(server)
                    }
                }
                .background(PendingNetTheme.Palette.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
                }
            }
        }
    }

    private func vpsRow(_ server: IOSPairedServer) -> some View {
        let selected = server.serverID == controller.selectedServerID
        let switching = controller.switchingServerID == server.serverID
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PendingNetTheme.Palette.accent)
                .opacity(selected ? 1 : 0)
                .frame(width: 14)
            // verbatim: 地址是标识符，不能被本地化
            Text(verbatim: server.address)
                .font(selected
                    ? PendingNetTheme.Fonts.bodyEmphasized.monospaced()
                    : PendingNetTheme.Fonts.body.monospaced())
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            if switching {
                ProgressView().controlSize(.small)
            } else {
                Button("详情") { detailServerID = server.serverID }
                    .buttonStyle(.plain)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected, controller.switchingServerID == nil, !controller.working else { return }
            Task { await controller.select(server) }
        }
    }

    // MARK: - 协议

    /// 协议手选与测速。只在隧道在位、且控制通道已经推回分组成员时出现——
    /// 这两个动作都要经 command client 连扩展里的 command server，隧道没起
    /// 来时无从谈起。切换与测速都不重启隧道。
    private var outboundPills: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer()
                Button {
                    Task { await runURLTest() }
                } label: {
                    HStack(spacing: 6) {
                        if testingOutbounds {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "bolt.horizontal")
                        }
                        Text(testingOutbounds ? "测速中…" : "测速")
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(testingOutbounds)
            }

            PendingWrapLayout {
                ForEach(controller.tunnel.outboundMembers, id: \.self) { tag in
                    outboundPill(tag)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func outboundPill(_ tag: String) -> some View {
        let selected = controller.tunnel.currentOutbound == tag
        let switching = switchingOutbound == tag
        return PendingPill(
            title: outboundTitle(tag),
            selected: selected
        ) {
            guard !selected, switchingOutbound == nil else { return }
            Task {
                switchingOutbound = tag
                defer { switchingOutbound = nil }
                do {
                    try await controller.tunnel.selectOutbound(tag)
                } catch {
                    controller.errorMessage = error.localizedDescription
                }
            }
        } accessory: {
            // 延迟贴在药丸里，不另起一行：药丸本身就是这一项的全部信息。
            if switching {
                ProgressView().controlSize(.small)
            } else if let delay = controller.tunnel.outboundDelays[tag], delay > 0 {
                Text(verbatim: "\(delay)ms")
                    .font(PendingNetTheme.Fonts.caption.monospaced())
                    .foregroundStyle(selected
                        ? PendingNetTheme.Palette.onAccent.opacity(0.75)
                        : PendingNetTheme.Palette.inkMuted)
            }
        }
    }

    private func runURLTest() async {
        testingOutbounds = true
        defer { testingOutbounds = false }
        let before = controller.tunnel.outboundDelays
        do {
            try await controller.tunnel.runURLTest()
        } catch {
            controller.errorMessage = error.localizedDescription
            return
        }
        // urlTest 只是触发，延迟随下一轮分组推送才回来。转圈要一直转到数字
        // 真的变了（或等够了），否则用户会看到「测速完成但一个数字没动」。
        await controller.tunnel.awaitDelayChange(from: before)
    }

    /// 成员 tag 形如 `<selectorTag>-<protocolID>`，外加一个 `-mix`（urltest，
    /// 代表自动选最快）。展示名回到节点资料里查，查不到就退回后缀本身。
    private func outboundTitle(_ tag: String) -> String {
        guard let selectorTag = controller.tunnel.selectorTag,
              tag.hasPrefix(selectorTag + "-") else { return tag }
        let suffix = String(tag.dropFirst(selectorTag.count + 1))
        if suffix == "mix" { return "自动（最快）" }
        return controller.nodeProfile?.protocols.first { $0.id == suffix }?.displayName ?? suffix
    }

    // MARK: - 状态

    /// 与 `outboundPills` 用的 `isTunnelLive` 保持一致（`.connected` 或
    /// `.reasserting`）。之前这里只认 `.connected`/`.connecting`，导致
    /// `.reasserting`（Wi-Fi/蜂窝切换重新握手）时开关显示「未连接」，但协议
    /// 选择器却因为 `isTunnelLive` 已经在显示——同一个隧道状态，开关和
    /// 选择器给用户两个矛盾的答案。
    private var isConnected: Bool {
        controller.tunnel.isTunnelLive || controller.tunnel.status == .connecting
    }

    private var isBusy: Bool {
        controller.tunnel.status == .connecting || controller.tunnel.status == .disconnecting
    }

    private var statusKind: PendingStatusPill.Kind {
        switch controller.tunnel.status {
        case .connected: .success
        case .invalid: .danger
        default: .neutral
        }
    }

    private var statusText: String {
        switch controller.tunnel.status {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnecting: "断开中"
        case .disconnected: "未连接"
        case .invalid: "未安装"
        case .reasserting: "重连中"
        @unknown default: "未知"
        }
    }

    private func messageBanner(_ text: String, kind: PendingStatusPill.Kind) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .danger
                ? "exclamationmark.circle.fill"
                : "checkmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(PendingNetTheme.Fonts.caption)
        .foregroundStyle(kind == .danger
            ? PendingNetTheme.Palette.danger
            : PendingNetTheme.Palette.success)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind == .danger
            ? PendingNetTheme.Palette.dangerBackground
            : PendingNetTheme.Palette.accentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 端口、支持的协议 —— 列表行上只放 IP，细节都在这里。macOS 上这是个
/// popover，iPhone 上没有 popover 的位置，用半屏 sheet 是 iOS 的惯例。
struct PendingNetServerDetailSheet: View {
    let server: IOSPairedServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailRow("名称", server.name)
                    detailRow("地址", server.address, monospaced: true)
                    if let port = server.controlPort {
                        // verbatim: 端口是标识符不是数量（否则 7443 会被显示成 "7,443"）
                        detailRow("端口", port, monospaced: true)
                    }
                    if let protocols = server.nodeProtocols, !protocols.isEmpty {
                        detailRow("支持的协议", protocols.joined(separator: " · "))
                    }
                }
                .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .tint(PendingNetTheme.Palette.accent)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
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
