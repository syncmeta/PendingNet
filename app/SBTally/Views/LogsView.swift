import SBTallyCore
import SwiftUI

private enum PendingNetLogSource: String, CaseIterable, Identifiable {
    case engine
    case stats
    case helper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engine: "sing-box"
        case .stats: "统计服务"
        case .helper: "后台服务"
        }
    }

    func path(takeover: String) -> String {
        if takeover == "local" {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let engine = support.appendingPathComponent("PendingNet/engine", isDirectory: true)
            switch self {
            case .engine: return engine.appendingPathComponent("sing-box.log").path
            case .stats: return engine.appendingPathComponent("sbtally.log").path
            case .helper: return "/var/log/pendingnet-helper.log"
            }
        }
        switch self {
        case .engine: return PendingNetEngineDaemon.logPath
        case .stats: return "/var/log/pendingnet-stats.log"
        case .helper: return "/var/log/pendingnet-helper.log"
        }
    }
}

/// macOS 诊断日志。只看文件尾巴，不把历史上可能长到数百 MB 的日志整份塞进
/// SwiftUI；TUN / 系统代理与仅端口使用的是两套进程，路径跟着当前接管方式切换。
struct LogsView: View {
    @EnvironmentObject private var engine: EngineController
    @State private var source: PendingNetLogSource = .engine
    @State private var text = ""
    @State private var error: String?
    @State private var loadedPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                PendingPageHeader(title: "日志")
                Spacer()
                Picker("日志来源", selection: $source) {
                    ForEach(PendingNetLogSource.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 292)
                Button {
                    load()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PendingQuietButtonStyle())
            }

            Text(verbatim: loadedPath)
                .font(PendingNetTheme.Fonts.caption.monospaced())
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                .textSelection(.enabled)
                .lineLimit(2)

            logContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PendingNetTheme.Metrics.gutter)
        .background(PendingNetTheme.Palette.canvas)
        .task(id: "\(source.rawValue)-\(engine.takeover)") { load() }
    }

    @ViewBuilder
    private var logContent: some View {
        if let error {
            ContentUnavailableView(
                "读不到日志",
                systemImage: "doc.text.magnifyingglass",
                description: Text(error)
            )
        } else if text.isEmpty {
            ContentUnavailableView(
                "日志为空",
                systemImage: "doc.text",
                description: Text("这项服务还没有写入日志。")
            )
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(PendingNetTheme.Palette.surface)
            .clipShape(RoundedRectangle(
                cornerRadius: PendingNetTheme.Metrics.cardRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: PendingNetTheme.Metrics.cardRadius,
                    style: .continuous
                )
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
            }
        }
    }

    private func load() {
        let path = source.path(takeover: engine.takeover)
        loadedPath = path
        do {
            text = try PendingNetLogTail.read(path: path)
            error = nil
        } catch CocoaError.fileReadNoSuchFile {
            text = ""
            error = "还没有生成这份日志。"
        } catch let readError {
            text = ""
            error = readError.localizedDescription
        }
    }
}
