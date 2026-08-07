import SBTallyCore
import SwiftUI
import UIKit

/// 隧道诊断日志查看器。
///
/// `PacketTunnelProvider` 把 sing-box 的 stderr（经 `LibboxRedirectStderr`）
/// 写到 App Group 里的 `stderr.log`，这是真机排障唯一的日志出口——扩展
/// 进程崩了或连不上，command client 都够不到它。这个视图只做最朴素的
/// 事情：读文件尾部、显示、复制、分享，不流式刷新、不常驻主界面。
struct PendingNetTunnelLogView: View {
    @Environment(\.dismiss) private var dismiss

    /// 只读文件尾部这么多字节，避免把一个几十 MB 的日志整个读进内存。
    private static let maxTailBytes: Int64 = 256 * 1024

    @State private var tail = ""
    @State private var truncated = false
    @State private var loadError: String?
    @State private var logURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let loadError {
                        PendingEmptyState(
                            icon: "doc.text.magnifyingglass",
                            title: "还没有日志",
                            detail: loadError
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        if truncated {
                            Text("文件较大，只显示末尾 \(Self.maxTailBytes / 1024) KB。完整内容请用右上角分享导出。")
                                .font(PendingNetTheme.Fonts.caption)
                                .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                        }
                        Text(tail.isEmpty ? "（日志为空）" : tail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PendingNetTheme.Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        UIPasteboard.general.string = tail
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(tail.isEmpty)
                    if let logURL {
                        ShareLink(item: logURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task { load() }
        }
    }

    /// 同步读文件——只取尾部，文件不存在或读不到时给出可读的空态，
    /// 不让一个损坏/缺失的日志文件把这个诊断页面本身也崩掉。
    private func load() {
        loadError = nil
        guard let base = PendingNetTunnelPaths.container() else {
            loadError = "无法访问 App Group 容器"
            logURL = nil
            return
        }
        let url = PendingNetTunnelPaths.stderrLogURL(in: base)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            loadError = "隧道还没有产生过日志，先连接一次再来看。"
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
