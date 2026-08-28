import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 唯一的导入入口：粘贴分享链接，一行一个节点。
struct PendingPasteImportSheet: View {
    let busy: Bool
    let onImport: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入节点")
                    .font(PendingNetTheme.Fonts.sectionTitle("导入节点"))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                Text("粘贴 pendingnet://、vless:// 或 hysteria2:// 分享链接；批量导入时一行一个节点。")
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(PendingNetTheme.Palette.ink)
                .scrollContentBackground(.hidden)
                .textEditorAutocapitalizationOff()
                .padding(8)
                .frame(minHeight: 130)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(PendingNetTheme.Palette.surfaceMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
                )
                .disabled(busy)

            HStack(spacing: 10) {
                Button("从剪贴板粘贴") {
                    if let clipboard = Self.clipboardText() { text = clipboard }
                }
                .buttonStyle(PendingQuietButtonStyle(fill: PendingNetTheme.Palette.surface))
                .disabled(busy)

                Spacer(minLength: 8)

                Button("取消", action: onCancel)
                    .buttonStyle(PendingQuietButtonStyle(fill: PendingNetTheme.Palette.surface))
                    .disabled(busy)

                Button {
                    onImport(text)
                } label: {
                    if busy {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在导入…")
                        }
                    } else {
                        Text("导入")
                    }
                }
                .buttonStyle(PendingPrimaryButtonStyle())
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(PendingNetTheme.Metrics.gutter)
        .frame(minWidth: 360)
        .background(PendingNetTheme.Palette.canvas)
    }

    private static func clipboardText() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}

private extension View {
    /// 链接是一串大小写敏感的 base64url，iOS 的自动大写和自动更正会当场毁掉它。
    /// macOS 上这些修饰符不存在，所以隔开写。
    @ViewBuilder
    func textEditorAutocapitalizationOff() -> some View {
        #if canImport(UIKit)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }
}
