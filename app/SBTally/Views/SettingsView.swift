import SBTallyCore
import SwiftUI

private struct RuleSetInfo: Decodable, Identifiable {
    var tag: String
    var file: String
    var updated_at: String
    var id: String { tag }
}

struct SettingsView: View {
    @EnvironmentObject private var updater: PendingNetUpdateController
    @EnvironmentObject private var engine: EngineController

    @State private var rulesets: [RuleSetInfo] = []
    @State private var rulesetsUpdating = false
    @State private var rulesetsUnavailable = false

    @State private var portField = ""
    @State private var portSaving = false
    @State private var portError: String?
    @State private var portSaved = false

    private let daemonBaseURL = URL(string: "http://127.0.0.1:7777")!

    private func loadRulesets() async {
        do {
            let url = daemonBaseURL.appendingPathComponent("/api/rulesets")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            rulesets = try JSONDecoder().decode([RuleSetInfo].self, from: data)
            rulesetsUnavailable = false
        } catch {
            rulesetsUnavailable = true
        }
    }

    private func updateRulesets() async {
        rulesetsUpdating = true
        defer { rulesetsUpdating = false }
        do {
            var request = URLRequest(url: daemonBaseURL.appendingPathComponent("/api/rulesets/update"))
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            await loadRulesets()
        } catch {
            rulesetsUnavailable = true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PendingPageHeader(title: "设置")
                localPortCard
                rulesCard
                appUpdateCard
            }
            .padding(PendingNetTheme.Metrics.gutter)
            .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .task {
            portField = String(engine.localProxyPort)
            await loadRulesets()
        }
    }

    /// 端口与监听范围。连接页不再显示它们，要看要改都在这里。
    private var localPortCard: some View {
        PendingSectionCard("端口") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // verbatim: 地址和端口都是标识符，别被本地化成 "2,080"
                    Text(verbatim: "\(engine.localListenAddress) :")
                        .font(PendingNetTheme.Fonts.body.monospaced())
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    TextField("", text: $portField)
                        .textFieldStyle(.roundedBorder)
                        .font(PendingNetTheme.Fonts.body.monospaced())
                        .frame(width: 92)
                        .onSubmit { saveInbound() }
                    Button("保存") { saveInbound() }
                        .buttonStyle(PendingQuietButtonStyle())
                        .disabled(portSaving || portField == String(engine.localProxyPort))
                    if portSaving { ProgressView().controlSize(.small) }
                    Spacer()
                }

                Toggle("允许局域网访问", isOn: Binding(
                    get: { engine.allowsLAN },
                    set: { on in saveInbound(allowLAN: on) }
                ))
                .toggleStyle(.switch)
                .font(PendingNetTheme.Fonts.body)
                .foregroundStyle(PendingNetTheme.Palette.ink)

                Text(engine.allowsLAN
                     ? "同一个网络里的设备都能通过这台机器上网 —— 在家或办公室方便，在咖啡馆之类的公共 Wi-Fi 就别开。"
                     : "只有这台电脑自己能用。开了之后同网段的设备也能连，监听地址会变成 0.0.0.0。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let portError {
                    Text(portError)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if portSaved {
                    Text(engine.running
                         ? "已改好，引擎已经按新设置重开了。"
                         : "已改好，下次连接生效。")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.success)
                }
            }
        }
    }

    private func saveInbound(allowLAN: Bool? = nil) {
        portSaved = false
        guard let port = Int(portField.trimmingCharacters(in: .whitespaces)) else {
            portError = "端口只能是数字，比如 2080。"
            return
        }
        portError = nil
        portSaving = true
        Task {
            let failure = await engine.setLocalInbound(
                port: port,
                allowLAN: allowLAN ?? engine.allowsLAN
            )
            portSaving = false
            portError = failure
            portSaved = failure == nil
            portField = String(engine.localProxyPort)
        }
    }

    private var rulesCard: some View {
        PendingSectionCard("规则集") {
            VStack(alignment: .leading, spacing: 12) {
                if rulesetsUnavailable {
                    Text("统计与规则服务尚未启用")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                } else if rulesets.isEmpty {
                    Text("暂无规则集")
                        .font(PendingNetTheme.Fonts.body)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                } else {
                    ForEach(rulesets) { ruleset in
                        HStack {
                            Text(ruleset.tag)
                                .font(PendingNetTheme.Fonts.bodyEmphasized)
                            Spacer()
                            Text(ruleset.updated_at)
                                .font(PendingNetTheme.Fonts.caption)
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        }
                    }
                }

                Button {
                    Task { await updateRulesets() }
                } label: {
                    if rulesetsUpdating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                        }
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(PendingQuietButtonStyle())
                .disabled(rulesetsUpdating)
            }
        }
    }

    private var appUpdateCard: some View {
        PendingSectionCard("更新") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // verbatim: 版本号是标识符，不是数量
                    Text(verbatim: "当前版本 \(updater.currentVersion)")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Spacer()
                    Button("检查更新…") { updater.checkForUpdates() }
                        .buttonStyle(PendingQuietButtonStyle())
                        .disabled(!updater.canCheckForUpdates)
                }

                if updater.isConfigured {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .toggleStyle(.switch)
                    Toggle("有更新时后台下载好", isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.automaticallyDownloadsUpdates = $0 }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!updater.automaticallyChecksForUpdates)
                } else {
                    Text("更新发布地址尚未配置")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
            }
            .font(PendingNetTheme.Fonts.body)
            .foregroundStyle(PendingNetTheme.Palette.ink)
        }
    }
}
