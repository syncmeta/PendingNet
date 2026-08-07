import SBTallyCore
import SwiftUI
import UIKit

/// 隧道诊断日志查看器。
///
/// 真机排障有三条**互不替代**的通道，这个页面把三条都摆出来：
///
/// 1. **上次启动失败**（`last-error.txt`）——扩展 `startTunnel` 抛出的错误
///    原文。`NEVPNConnection` 不把扩展的错误传给 App，没有这个文件，
///    「隧道起不来」在 App 里就是一个没有线索的黑盒。
/// 2. **内核日志**（command client 订阅 `LibboxCommandLog`）——sing-box 自己
///    的日志**只有**这一个出口：libbox 有 platform interface 时会把
///    `defaultLogWriter` 设成 `io.Discard`，日志只进 command server 的环形
///    缓冲。要隧道活着才读得到。
/// 3. **扩展自身日志**（App Group 里的 `stderr.log`）——扩展 `writeMessage`
///    写的诊断行，由扩展自己 `freopen` 把 fd 2 接过去。隧道挂了之后仍然读
///    得到，但里面**没有** sing-box 的日志。
///
/// 早先这里只读一个文件，并且以为那个文件里同时有 1 和 2——两条都不成立，
/// 结果是这个页面永远显示「隧道还没有产生过日志」。
struct PendingNetTunnelLogView: View {
    @Environment(\.dismiss) private var dismiss

    /// 只读文件尾部这么多字节，避免把一个几十 MB 的日志整个读进内存。
    private static let maxTailBytes: Int64 = 256 * 1024

    private enum Channel: String, CaseIterable {
        case kernel
        case extensionSelf

        var title: String {
            switch self {
            case .kernel: "内核日志"
            case .extensionSelf: "扩展日志"
            }
        }
    }

    @StateObject private var kernelLog = KernelLogFeed()
    @State private var channel: Channel = .kernel
    @State private var tail = ""
    @State private var truncated = false
    @State private var loadError: String?
    @State private var logURL: URL?
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let lastError {
                        lastErrorCard(lastError)
                    }

                    Picker("通道", selection: $channel) {
                        ForEach(Channel.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch channel {
                    case .kernel: kernelSection
                    case .extensionSelf: extensionSection
                    }
                }
                .padding(PendingNetTheme.Metrics.gutter)
            }
            .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("隧道日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = currentText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(currentText.isEmpty)
                    if channel == .extensionSelf, let logURL {
                        ShareLink(item: logURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            // 日志订阅只在这个页面打开时存在：扩展只有约 50MB 额度，不该为
            // 一个没人看的页面持续往 socket 里序列化日志。
            .task {
                load()
                kernelLog.start()
            }
            .onDisappear { kernelLog.stop() }
        }
    }

    private var currentText: String {
        channel == .kernel ? kernelLog.text : tail
    }

    @ViewBuilder
    private var kernelSection: some View {
        if kernelLog.lines.isEmpty {
            PendingEmptyState(
                icon: "waveform.path.ecg",
                title: "还没有内核日志",
                detail: "内核日志只能在隧道运行时读取。连接之后回到这里，"
                    + "扩展里已经缓存的日志会一次性回放上来。"
            )
            .frame(maxWidth: .infinity)
        } else {
            monospaced(kernelLog.text)
        }
    }

    @ViewBuilder
    private var extensionSection: some View {
        if let loadError {
            PendingEmptyState(
                icon: "doc.text.magnifyingglass",
                title: "还没有扩展日志",
                detail: loadError
            )
            .frame(maxWidth: .infinity)
        } else {
            if truncated {
                Text("文件较大，只显示末尾 \(Self.maxTailBytes / 1024) KB。完整内容请用右上角分享导出。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            }
            Text("这里只有扩展自己写的诊断行，没有 sing-box 的内核日志。")
                .font(PendingNetTheme.Fonts.caption)
                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            monospaced(tail.isEmpty ? "（日志为空）" : tail)
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(PendingNetTheme.Palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastErrorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("上次启动失败", systemImage: "exclamationmark.triangle.fill")
                .font(PendingNetTheme.Fonts.bodyEmphasized)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PendingNetTheme.Palette.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PendingNetTheme.Palette.dangerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 同步读文件——只取尾部，文件不存在或读不到时给出可读的空态，
    /// 不让一个损坏/缺失的日志文件把这个诊断页面本身也崩掉。
    private func load() {
        loadError = nil
        lastError = nil
        guard let base = PendingNetTunnelPaths.container() else {
            loadError = "无法访问 App Group 容器"
            logURL = nil
            return
        }
        lastError = (try? String(
            contentsOf: PendingNetTunnelPaths.lastErrorURL(in: base),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastError?.isEmpty == true { lastError = nil }

        let url = PendingNetTunnelPaths.stderrLogURL(in: base)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            loadError = "隧道还没有产生过扩展日志，先连接一次再来看。"
            logURL = nil
            tail = ""
            return
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            loadError = "无法打开日志文件"
            logURL = nil
            return
        }
        defer { handle.closeFile() }

        let size = (try? handle.seekToEnd()) ?? 0
        do {
            if size > UInt64(Self.maxTailBytes) {
                truncated = true
                try handle.seek(toOffset: size - UInt64(Self.maxTailBytes))
            } else {
                truncated = false
                try handle.seek(toOffset: 0)
            }
        } catch {
            loadError = "读取日志失败：\(error.localizedDescription)"
            logURL = nil
            return
        }
        let data = handle.readDataToEndOfFile()
        tail = String(decoding: data, as: UTF8.self)
        logURL = url
    }
}

/// sing-box 内核日志的实时订阅。
///
/// 走 `PendingNetCommandClient` 的 `LibboxCommandLog` 通道——这是内核日志
/// 唯一的出口。连上时扩展会先把环形缓冲（`logMaxLines = 500`）整批回放，
/// 所以隧道启动那几行也拿得到。隧道没连上时 client 自己退避重连，页面显示
/// 空态即可。
@MainActor
private final class KernelLogFeed: ObservableObject {
    /// 上限跟扩展的环形缓冲对齐：再多留在 App 里也没有对应的来源。
    private static let maxLines = 500

    @Published private(set) var lines: [String] = []

    var text: String { lines.joined(separator: "\n") }

    private var client: PendingNetCommandClient?

    func start() {
        guard client == nil else { return }
        let client = PendingNetCommandClient(onLogEvent: { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        })
        self.client = client
        client.startLogs()
    }

    func stop() {
        client?.stop()
        client = nil
    }

    private func apply(_ event: PendingNetCommandClient.LogEvent) {
        switch event {
        case .clear:
            lines = []
        case .append(let new):
            lines.append(contentsOf: new)
            if lines.count > Self.maxLines {
                lines.removeFirst(lines.count - Self.maxLines)
            }
        }
    }
}
