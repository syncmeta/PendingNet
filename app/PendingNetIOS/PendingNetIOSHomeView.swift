import NetworkExtension
import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

struct PendingNetIOSHomeView: View {
    @EnvironmentObject private var controller: PendingNetIOSController
    @State private var showingImporter = false
    @State private var showingLog = false

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
                                try await controller.tunnel.start(
                                    profile: profile,
                                    serverName: serverName,
                                    serverID: profile.serverID
                                )
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
            }
        }
    }

    private var isConnected: Bool {
        controller.tunnel.status == .connected || controller.tunnel.status == .connecting
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
