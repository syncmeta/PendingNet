import NetworkExtension
import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct PendingNetIOSHomeView: View {
    @EnvironmentObject private var controller: PendingNetIOSController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImporter = false
    @State private var showingLog = false
    @State private var testingOutbounds = false
    @State private var switchingOutbound: String?
    @State private var switchingRouteMode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PendingPageHeader(
                        title: "PendingNet",
                        subtitle: "连接自己的 VPS，规则留在自己的设备上。"
                    )
                    serverCard
                    tunnelCard

                    if let server = controller.server, let profile = controller.nodeProfile {
                        tunnelSection(profile: profile, serverName: server.name)
                    }

                    if let message = controller.message {
                        messageBanner(message, success: true)
                    }
                    if let error = controller.errorMessage {
                        messageBanner(error, success: false)
                    }
                }
                .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
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

    private var serverCard: some View {
        PendingSectionCard(
            "VPS",
            subtitle: ".pdn 只用于一次配对，协议材料由 VPS 后续下发。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let server = controller.server {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(PendingNetTheme.Palette.accentBackground)
                            Image(systemName: "server.rack")
                                .foregroundStyle(PendingNetTheme.Palette.accent)
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name)
                                .font(PendingNetTheme.Fonts.bodyEmphasized)
                                .foregroundStyle(PendingNetTheme.Palette.ink)
                            Text(server.endpoint)
                                .font(PendingNetTheme.Fonts.caption.monospaced())
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        PendingStatusPill(text: "已配对", kind: .success)
                    }
                } else {
                    PendingEmptyState(
                        icon: "server.rack",
                        title: "还没有配对 VPS",
                        detail: "请导入 VPS 生成的 .pdn 配对文件。"
                    )
                    .frame(maxWidth: .infinity)
                }

                Button {
                    showingImporter = true
                } label: {
                    HStack(spacing: 8) {
                        if controller.working {
                            ProgressView().tint(PendingNetTheme.Palette.onAccent)
                            Text("正在配对…")
                        } else {
                            Image(systemName: "square.and.arrow.down")
                            Text(controller.server == nil ? "导入 .pdn" : "重新配对")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PendingPrimaryButtonStyle())
                .disabled(controller.working)
            }
        }
    }

    private var tunnelCard: some View {
        PendingSectionCard(
            "连接",
            subtitle: "路由规则由本机管理，不会写回 VPS。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Packet Tunnel", systemImage: "checkmark.shield")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    PendingStatusPill(
                        text: controller.nodeProfile == nil ? "等待配置" : "配置就绪",
                        kind: controller.nodeProfile == nil ? .neutral : .success
                    )
                }

                if let profile = controller.nodeProfile {
                    Divider().overlay(PendingNetTheme.Palette.hairline)
                    ForEach(profile.protocols) { item in
                        HStack(spacing: 9) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(PendingNetTheme.Palette.accent)
                            Text(item.displayName)
                                .font(PendingNetTheme.Fonts.body)
                                .foregroundStyle(PendingNetTheme.Palette.ink)
                        }
                    }
                } else {
                    Text("配对后会自动从 VPS 读取协议连接材料。")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func tunnelSection(
        profile: PendingNetNodeProfile,
        serverName: String
    ) -> some View {
        PendingSectionCard(
            "隧道",
            subtitle: "开关由本机 Packet Tunnel 扩展驱动，VPS 不参与开关状态。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("PendingNet Tunnel", systemImage: "checkmark.shield")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    PendingStatusPill(text: statusText, kind: statusKind)
                }

                Button {
                    Task {
                        if isConnected {
                            await controller.tunnel.stop()
                        } else {
                            do {
                                controller.errorMessage = nil
                                try await controller.tunnel.start(
                                    profile: profile,
                                    serverName: serverName,
                                    serverID: profile.serverID
                                )
                                // 规则集不可用时 start 会降级到全局代理而不是
                                // 失败；降级必须让用户看见，否则界面上的
                                // 「绕过大陆」会悄悄变成「全局代理」。
                                if let notice = controller.tunnel.degradeNotice {
                                    controller.errorMessage = notice
                                    controller.tunnel.degradeNotice = nil
                                }
                            } catch {
                                controller.errorMessage = error.localizedDescription
                            }
                        }
                    }
                } label: {
                    Text(isConnected ? "断开" : "连接")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PendingPrimaryButtonStyle())
                .disabled(isBusy)

                routeModePicker(profile: profile, serverName: serverName)

                if controller.tunnel.isTunnelLive,
                   !controller.tunnel.outboundMembers.isEmpty {
                    outboundPicker(profile: profile)
                }
            }
        }
    }

    /// 三档分流模式。切换只做两件事：落 `routeMode`（`.bypassCN` 之前先
    /// 确保规则集在），隧道在位再 `reload` 把新配置真正推给扩展。两者都
    /// 不重启隧道进程本身——`.bypassCN`/`.direct` 的差别只在 sing-box 的
    /// route/dns 段，`reload` 走的是已经建立的 `sendProviderMessage`
    /// 通道。未连接时只落地 `routeMode`，下一次 `start` 会带着它生效。
    @ViewBuilder
    private func routeModePicker(
        profile: PendingNetNodeProfile,
        serverName: String
    ) -> some View {
        Divider().overlay(PendingNetTheme.Palette.hairline)

        HStack {
            Text("分流模式")
                .font(PendingNetTheme.Fonts.bodyEmphasized)
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            if switchingRouteMode {
                ProgressView().controlSize(.small)
            }
        }

        Picker("分流模式", selection: Binding(
            get: { controller.tunnel.routeMode },
            set: { mode in
                Task { await switchRouteMode(to: mode, profile: profile, serverName: serverName) }
            }
        )) {
            ForEach(PendingNetRouteMode.allCases, id: \.self) { mode in
                Text(routeModeTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(switchingRouteMode)

        Text(routeModeDetail(controller.tunnel.routeMode))
            .font(PendingNetTheme.Fonts.caption)
            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
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

    private func routeModeDetail(_ mode: PendingNetRouteMode) -> String {
        switch mode {
        case .global: "所有流量都走 VPS。"
        case .bypassCN: "国内域名与 IP 直连，其余走 VPS；需要先下载规则集。"
        case .direct: "应急模式：VPN 保持开启，但流量不经 VPS，全部直连。"
        }
    }

    /// 协议手选与测速。只在隧道在位、且控制通道已经推回分组成员时出现——
    /// 这两个动作都要经 command client 连扩展里的 command server，隧道没起
    /// 来时无从谈起。切换与测速都不重启隧道。
    @ViewBuilder
    private func outboundPicker(profile: PendingNetNodeProfile) -> some View {
        Divider().overlay(PendingNetTheme.Palette.hairline)

        HStack {
            Text("协议")
                .font(PendingNetTheme.Fonts.bodyEmphasized)
                .foregroundStyle(PendingNetTheme.Palette.ink)
            Spacer()
            Button {
                Task {
                    testingOutbounds = true
                    defer { testingOutbounds = false }
                    let before = controller.tunnel.outboundDelays
                    do {
                        try await controller.tunnel.runURLTest()
                    } catch {
                        controller.errorMessage = error.localizedDescription
                        return
                    }
                    // urlTest 只是触发，延迟随下一轮分组推送才回来。转圈要
                    // 一直转到数字真的变了（或等够了），否则用户会看到
                    // 「测速完成但一个数字没动」。
                    await controller.tunnel.awaitDelayChange(from: before)
                }
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

        ForEach(controller.tunnel.outboundMembers, id: \.self) { tag in
            outboundRow(tag: tag, profile: profile)
        }

        Text("切换协议经隧道内的控制通道生效，不会重启隧道、也不会断开已有连接。")
            .font(PendingNetTheme.Fonts.caption)
            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
    }

    private func outboundRow(tag: String, profile: PendingNetNodeProfile) -> some View {
        let selected = controller.tunnel.currentOutbound == tag
        let switching = switchingOutbound == tag
        return Button {
            guard !selected else { return }
            Task {
                switchingOutbound = tag
                defer { switchingOutbound = nil }
                do {
                    try await controller.tunnel.selectOutbound(tag)
                } catch {
                    controller.errorMessage = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected
                        ? PendingNetTheme.Palette.accent
                        : PendingNetTheme.Palette.inkMuted)
                Text(outboundTitle(tag, profile: profile))
                    .font(PendingNetTheme.Fonts.body)
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                Spacer()
                if switching {
                    ProgressView().controlSize(.small)
                } else {
                    PendingStatusPill(text: delayText(tag), kind: delayKind(tag))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switchingOutbound != nil)
    }

    /// 成员 tag 形如 `<selectorTag>-<protocolID>`，外加一个 `-mix`（urltest，
    /// 代表自动选最快）。展示名回到节点资料里查，查不到就退回后缀本身。
    private func outboundTitle(_ tag: String, profile: PendingNetNodeProfile) -> String {
        guard let selectorTag = controller.tunnel.selectorTag,
              tag.hasPrefix(selectorTag + "-") else { return tag }
        let suffix = String(tag.dropFirst(selectorTag.count + 1))
        if suffix == "mix" { return "自动（最快）" }
        return profile.protocols.first { $0.id == suffix }?.displayName ?? suffix
    }

    /// 内核用 0 表示「这一项还没有测速结果」。
    private func delayText(_ tag: String) -> String {
        guard let delay = controller.tunnel.outboundDelays[tag], delay > 0 else {
            return "未测速"
        }
        return "\(delay) ms"
    }

    private func delayKind(_ tag: String) -> PendingStatusPill.Kind {
        guard let delay = controller.tunnel.outboundDelays[tag], delay > 0 else {
            return .neutral
        }
        return delay <= 300 ? .success : .neutral
    }

    /// 与 `outboundPicker` 用的 `isTunnelLive` 保持一致（`.connected` 或
    /// `.reasserting`）。之前这里只认 `.connected`/`.connecting`，导致
    /// `.reasserting`（Wi-Fi/蜂窝切换重新握手）时按钮显示「连接」，但协议
    /// 选择器却因为 `isTunnelLive` 已经在显示——同一个隧道状态，按钮和
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

    private func messageBanner(_ text: String, success: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(PendingNetTheme.Fonts.caption)
        .foregroundStyle(success ? PendingNetTheme.Palette.success : PendingNetTheme.Palette.danger)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(success
            ? PendingNetTheme.Palette.accentBackground
            : PendingNetTheme.Palette.dangerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
