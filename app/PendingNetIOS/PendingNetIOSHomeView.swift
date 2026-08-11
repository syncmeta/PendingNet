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
    @State private var switchingOutbound: String?
    @State private var switchingRouteMode = false
    @State private var detailServerID: String?
    /// 每台 VPS 一个延迟数，和 macOS 同一套语义、同一份实现
    /// （见 `PendingNetLatencyTarget`）。
    @StateObject private var latency = PendingNetLatencyTester()

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
            PendingNetServerDetailSheet(
                server: server,
                latency: latency.outcome(for: server.serverID),
                isMeasuring: latency.isMeasuring(server.serverID)
            ) {
                Task { await latency.measure(server) }
            }
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
        // 隧道一旦不在位，「切换中」标志必须无条件归位。它是 @State，活得比
        // 选择器的显示条件长：靠 RPC 自己返回来清是不够的（挂住的调用可能
        // 永远不返回），那样重连之后每一行都会是灰的、且没有任何用户可见的
        // 恢复路径。
        .onChange(of: controller.tunnel.isTunnelLive) { _, live in
            guard !live else { return }
            switchingOutbound = nil
        }
    }

    // MARK: - 一张卡，一种控件

    private var connectionCard: some View {
        PendingConnectionCard {
            header

            routeModePills

            vpsList
                .padding(.top, 10)

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
    }

    /// 状态药丸 + 原来的滑动开关。开关是「连接/断开」这一个动作，不是多选一，
    /// 所以它不做成药丸——这一点和 macOS 定稿一致。
    private var header: some View {
        PendingConnectionHeader(
            statusText: statusText,
            statusKind: statusKind,
            isBusy: isBusy,
            action: .toggle(
                isOn: isConnected,
                enabled: !isBusy && controller.server != nil && controller.nodeProfile != nil
            )
        ) { on in
            Task { await setConnected(on) }
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
            // 规则集不可用时 start 会降级到全局而不是失败；降级必须让
            // 用户看见，否则界面上的「白名单」会悄悄变成「全局」。
            if let notice = controller.tunnel.degradeNotice {
                controller.errorMessage = notice
                controller.tunnel.degradeNotice = nil
            }
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 路由

    /// 三档分流模式（与 macOS 同名同义）。切换只做两件事：落 `routeMode`
    /// （白名单 / 黑名单之前先确保规则集在），隧道在位再 `reload` 把新配置
    /// 真正推给扩展。两者都不重启隧道进程本身——三档的差别只在 sing-box 的
    /// route/dns 段，`reload` 走的是已经建立的 `sendProviderMessage`
    /// 通道。未连接时只落地 `routeMode`，下一次 `start` 会带着它生效。
    private var routeModePills: some View {
        PendingRouteModePicker(
            selection: controller.tunnel.routeMode,
            isEnabled: !switchingRouteMode
        ) { mode in
            guard let server = controller.server, let profile = controller.nodeProfile else { return }
            Task {
                await switchRouteMode(
                    to: mode,
                    profile: profile,
                    serverName: server.name
                )
            }
        }
    }

    /// 切换分流模式的完整流程，含降级。
    ///
    /// 白名单 / 黑名单都需要规则集：拿不到就不切——保持在原模式（多数情况下
    /// 是已经在用的全局），并提示用户，绝不能让隧道因为规则集缺失/损坏而
    /// 起不来。真正应用新模式（落地 `routeMode` + 已连接时 `reload`）统一
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

        // 只补这一档用得到的规则集：白名单不该因为它根本不引用的
        // geosite-gfw 下不来而开不了。
        if mode != .global {
            var reason: String?
            do {
                try await controller.ruleSetStore.ensureAvailable(for: mode)
                if !controller.ruleSetStore.isReady(for: mode) {
                    reason = "规则集文件不完整或不是有效的 .srs"
                }
            } catch {
                reason = error.localizedDescription
            }
            if let reason {
                controller.errorMessage = "规则集不可用，已保持全局：\(reason)"
                // 降级：确保隧道（如果在位）确实跑在全局上，而不是停在
                // 「用户点了白名单，但没人知道最终生效的是哪个模式」这种
                // 界面选中项和隧道实际配置对不上的状态。
                if previous != .global {
                    _ = await applyRouteMode(.global, previous: previous, profile: profile, serverName: serverName)
                }
                return
            }
        }

        if await applyRouteMode(mode, previous: previous, profile: profile, serverName: serverName) {
            controller.message = "已切换到「\(mode.pendingTitle)」"
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

    // MARK: - VPS：竖排列表，选中的那行前面打勾

    private var vpsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                if !controller.servers.isEmpty {
                    // 名字要说清它在测什么：逐台测一遍延迟，不是「测速」。
                    Button("测每台延迟") {
                        Task { await latency.measureAll(controller.servers) }
                    }
                    .buttonStyle(PendingQuietButtonStyle(
                        fill: PendingNetTheme.Palette.surface
                    ))
                    .disabled(latency.busy || controller.working)
                }
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
                .buttonStyle(PendingQuietButtonStyle(
                    fill: PendingNetTheme.Palette.surface
                ))
                .disabled(controller.working)
            }

            PendingVPSList(
                items: controller.servers,
                selectedID: controller.selectedServerID,
                switchingID: controller.switchingServerID,
                unpairedIDs: controller.unpairedServerIDs,
                latencies: latency.results
            ) { serverID in
                guard controller.switchingServerID == nil,
                      !controller.working,
                      let server = controller.servers.first(where: {
                          $0.serverID == serverID
                      })
                else { return }
                Task { await controller.select(server) }
            } onShowDetails: { serverID in
                detailServerID = serverID
            }

            if !controller.servers.isEmpty {
                Text("延迟是本机到这台 VPS 代理入口的一次 TCP 握手往返时间，越小越好；直连测量，不经隧道。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 协议

    /// 协议手选。只在隧道在位、且控制通道已经推回分组成员时出现——切换要经
    /// command client 连扩展里的 command server，隧道没起来时无从谈起。
    /// 切换不重启隧道。
    ///
    /// 这里以前还有一个「测速」按钮，按协议给出各自的 urltest 延迟。撤掉了：
    /// 同一台 VPS 的两个协议差出来的多半是偶然波动，摆成两个数字只会让人
    /// 以为要照着它挑协议。延迟现在是「一台 VPS 一个数」，在上面的 VPS
    /// 列表里。内核自己的 urltest 照旧跑，「混合」还是它在选。
    ///
    /// 选项名不在这里拼——两端共用 `PendingProtocolPicker`，名字统一走
    /// `PendingNetOutboundNaming`，Mac 和 iPhone 上才会一字不差。
    private var outboundPills: some View {
        PendingProtocolPicker(
            members: controller.tunnel.outboundMembers,
            selectorTag: controller.tunnel.selectorTag,
            selected: controller.tunnel.currentOutbound,
            switchingTag: switchingOutbound
        ) { tag in
            Task {
                switchingOutbound = tag
                defer { switchingOutbound = nil }
                do {
                    try await controller.tunnel.selectOutbound(tag)
                } catch {
                    controller.errorMessage = error.localizedDescription
                }
            }
        }
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
    let latency: PendingNetLatencyOutcome?
    let isMeasuring: Bool
    let onMeasure: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PendingVPSDetails(
                        server: server,
                        nameStyle: .labeledRow,
                        spacing: 12,
                        latency: latency
                    )

                    Button {
                        onMeasure()
                    } label: {
                        if isMeasuring {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在测延迟…")
                            }
                        } else {
                            Text("测这台的延迟")
                        }
                    }
                    .buttonStyle(PendingQuietButtonStyle(
                        fill: PendingNetTheme.Palette.surface
                    ))
                    .disabled(isMeasuring)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
}
