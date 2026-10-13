import SBTallyCore
import SwiftUI

struct PendingNetExportView: View {
    let server: PendingNetManagedServer
    @Environment(\.dismiss) private var dismiss
    @State private var profile: PendingNetNodeProfile?
    @State private var users: [PendingNetAdminUser] = []
    @State private var selectedUserID = ""
    @State private var options = PendingNetClientExportOptions()
    @State private var portText = "2080"
    @State private var errorMessage: String?
    @State private var document: PendingNetClientConfigDocument?
    @State private var showingExporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("导出 sing-box 配置文件").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !users.isEmpty {
                        Picker("用户", selection: $selectedUserID) {
                            Text("当前管理用户").tag("")
                            ForEach(users.filter { $0.revokedAt == nil }) { user in Text(verbatim: user.name).tag(user.id) }
                        }
                    }
                    Picker("平台", selection: $options.platform) {
                        Text("Android").tag(PendingNetClientExportOptions.Platform.android)
                        Text("Windows").tag(PendingNetClientExportOptions.Platform.windows)
                    }
                    Picker("接管方式", selection: $options.mode) {
                        Text("仅端口").tag(PendingNetClientExportOptions.Mode.port)
                        Text("系统代理").tag(PendingNetClientExportOptions.Mode.sysproxy)
                        Text("TUN").tag(PendingNetClientExportOptions.Mode.tun)
                    }
                    Picker("协议", selection: $options.protocolID) {
                        if let profile {
                            ForEach(profile.protocols, id: \.id) { item in Text(verbatim: item.displayName).tag(item.id) }
                            Text("混合").tag("mix")
                        }
                    }
                    HStack {
                        Text("代理端口")
                        TextField("端口", text: $portText).frame(maxWidth: 100)
                    }
                    Toggle("允许局域网访问", isOn: $options.allowsLAN)
                        .tint(PendingNetTheme.Palette.accent)
                    Text("此端口提供 HTTP/SOCKS 代理；TUN 使用虚拟网卡，不占用这个监听端口。")
                        .font(.caption).foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    if options.platform == .android && options.mode == .sysproxy {
                        Text("Android 系统代理需要系统权限；普通 VPN 客户端请选择 TUN。")
                            .font(.caption).foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    }
                    if options.mode == .tun {
                        Text("TUN 配置包含自动检测底层网络接口，避免节点连接被送回自身隧道。")
                            .font(.caption).foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    }
                    Text("导出的文件包含连接凭据，请妥善保管。")
                        .font(.caption).foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    if let errorMessage { Text(errorMessage).foregroundStyle(PendingNetTheme.Palette.danger) }
                    if profile == nil && errorMessage == nil { ProgressView() }
                }
            }
            Button("导出") { export() }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(profile == nil)
        }
        .padding(PendingNetTheme.Metrics.gutter)
        .frame(idealWidth: 480, idealHeight: 560)
        .task {
            do { users = try await PendingNetAdminAPIClient(server: server).users() }
            catch { errorMessage = error.localizedDescription }
        }
        .task(id: selectedUserID) {
            profile = nil
            do {
                let value = try await PendingNetAdminAPIClient(server: server).nodeProfile(userID: selectedUserID.isEmpty ? nil : selectedUserID)
                guard !Task.isCancelled else { return }
                profile = value; errorMessage = nil
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .fileExporter(isPresented: $showingExporter, document: document, contentType: .json,
            defaultFilename: "pendingnet-\(options.platform.rawValue)-\(options.mode.rawValue).json") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            document = nil
        }
    }
    private func export() {
        do {
            guard let profile, let port = Int(portText) else { throw PendingNetRuntimeConfigError.invalidLocalConfiguration }
            options.port = port
            document = PendingNetClientConfigDocument(data: try PendingNetClientExport.make(profile: profile, options: options))
            errorMessage = nil
            showingExporter = true
        } catch { errorMessage = error.localizedDescription }
    }
}
