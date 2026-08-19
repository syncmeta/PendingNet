import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 粘贴配对凭据的那个框。
///
/// 链接在聊天软件里常被吞、从手机传到电脑也麻烦，所以「复制一段文本粘进来」
/// 这条路必须在，而且要和「导入 .pdn」并排放 —— 同一件事的两种办法，不该分散
/// 在两个地方等用户去找。
///
/// 认链接也认 `.pdn` 原文（见 `PendingNetPairingFile.decode(pasted:)`）：这个框
/// 存在的理由就是「一定管用」，多认一种形态是免费的。
struct PendingPasteImportSheet: View {
    let busy: Bool
    let onImport: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("粘贴配对链接")
                    .font(PendingNetTheme.Fonts.sectionTitle("粘贴配对链接"))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                Text("把 VPS 上生成的 pendingnet:// 链接整条粘进来。.pdn 文件里的内容也认。")
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
                            Text("正在配对…")
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
