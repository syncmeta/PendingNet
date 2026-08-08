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

    @State private var rulesets: [RuleSetInfo] = []
    @State private var rulesetsUpdating = false
    @State private var rulesetsUnavailable = false

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
                rulesCard
                appUpdateCard
            }
            .padding(PendingNetTheme.Metrics.gutter)
            .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PendingNetTheme.Palette.canvas)
        .task { await loadRulesets() }
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
        PendingSectionCard("应用更新") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前版本 \(updater.currentVersion)")
                        .font(PendingNetTheme.Fonts.bodyEmphasized)
                        .foregroundStyle(PendingNetTheme.Palette.ink)
                    Text(updater.isConfigured
                         ? "已启用自动检查与后台下载"
                         : "更新发布地址尚未配置")
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
                Spacer()
                Button("检查更新…") { updater.checkForUpdates() }
                    .buttonStyle(PendingQuietButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
