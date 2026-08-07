import SwiftUI

enum PendingNetTheme {
    enum Palette {
        static let accent = Color.pendingAdaptive(light: 0x044735, dark: 0x57B690)
        static let accentHover = Color.pendingAdaptive(light: 0x0A6049, dark: 0x6CC6A1)
        static let accentBackground = Color.pendingAdaptive(light: 0xE3EEEA, dark: 0x1C3A2F)
        static let canvas = Color.pendingAdaptive(light: 0xFDFCFA, dark: 0x161512)
        static let surface = Color.pendingAdaptive(light: 0xFFFFFF, dark: 0x201E1A)
        static let surfaceMuted = Color.pendingAdaptive(light: 0xEFEEE9, dark: 0x2A2823)
        static let ink = Color.pendingAdaptive(light: 0x1B1A14, dark: 0xECE9E0)
        static let inkMuted = Color.pendingAdaptive(light: 0x6E6A5C, dark: 0xA8A294)
        static let hairline = Color.pendingAdaptive(light: 0xE2E0D7, dark: 0x383530)
        static let danger = Color.pendingAdaptive(light: 0xB14B3C, dark: 0xE08D7A)
        static let dangerBackground = Color.pendingAdaptive(light: 0xF4DDD6, dark: 0x3C241E)
        static let success = Color.pendingAdaptive(light: 0x2E7D5B, dark: 0x6FBF99)
        static let onAccent = Color.pendingAdaptive(light: 0xFFFFFF, dark: 0x0E2A20)
    }

    enum Fonts {
        static let pageTitle = Font.system(size: 25, weight: .semibold, design: .serif)
        static let sectionTitle = Font.system(size: 17, weight: .semibold, design: .serif)
        static let body = Font.system(size: 14)
        static let bodyEmphasized = Font.system(size: 14, weight: .medium)
        static let caption = Font.system(size: 12)
        static let chrome = Font.system(size: 13, weight: .medium, design: .rounded)

        static func pageTitle(_ text: String) -> Font {
            containsCJK(text)
                ? .system(size: 25, weight: .medium)
                : pageTitle
        }

        static func sectionTitle(_ text: String) -> Font {
            containsCJK(text)
                ? .system(size: 17, weight: .medium)
                : sectionTitle
        }

        private static func containsCJK(_ text: String) -> Bool {
            text.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                     0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2A6DF:
                    true
                default:
                    false
                }
            }
        }
    }

    enum Metrics {
        static let gutter: CGFloat = 20
        static let cardRadius: CGFloat = 14
        static let controlHeight: CGFloat = 36
        static let readableWidth: CGFloat = 820
    }
}

extension Color {
    static func pendingAdaptive(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            UIColor(pendingHex: traits.userInterfaceStyle == .dark ? dark : light, alpha: alpha)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let darkAppearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(pendingHex: darkAppearance ? dark : light, alpha: alpha)
        })
        #else
        return Color(.sRGB,
                     red: Double((light >> 16) & 0xFF) / 255,
                     green: Double((light >> 8) & 0xFF) / 255,
                     blue: Double(light & 0xFF) / 255,
                     opacity: alpha)
        #endif
    }
}

#if canImport(UIKit)
import UIKit

private extension UIColor {
    convenience init(pendingHex hex: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#elseif canImport(AppKit)
import AppKit

private extension NSColor {
    convenience init(pendingHex hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#endif

struct PendingPageHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PendingNetTheme.Fonts.pageTitle(title))
                .foregroundStyle(PendingNetTheme.Palette.ink)
            if let subtitle {
                Text(subtitle)
                    .font(PendingNetTheme.Fonts.body)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PendingSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PendingNetTheme.Fonts.sectionTitle(title))
                    .foregroundStyle(PendingNetTheme.Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(PendingNetTheme.Fonts.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PendingNetTheme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PendingNetTheme.Metrics.cardRadius, style: .continuous)
                .stroke(PendingNetTheme.Palette.hairline, lineWidth: 1)
        }
    }
}

struct PendingStatusPill: View {
    enum Kind { case neutral, success, danger }

    let text: String
    var kind: Kind = .neutral

    private var foreground: Color {
        switch kind {
        case .neutral: PendingNetTheme.Palette.inkMuted
        case .success: PendingNetTheme.Palette.success
        case .danger: PendingNetTheme.Palette.danger
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: PendingNetTheme.Palette.surfaceMuted
        case .success: PendingNetTheme.Palette.accentBackground
        case .danger: PendingNetTheme.Palette.dangerBackground
        }
    }

    var body: some View {
        Text(text)
            .font(PendingNetTheme.Fonts.chrome)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
    }
}

struct PendingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PendingNetTheme.Fonts.chrome)
            .foregroundStyle(PendingNetTheme.Palette.onAccent)
            .padding(.horizontal, 15)
            .frame(minHeight: PendingNetTheme.Metrics.controlHeight)
            .background(
                Capsule().fill(configuration.isPressed
                    ? PendingNetTheme.Palette.accentHover
                    : PendingNetTheme.Palette.accent)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct PendingQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PendingNetTheme.Fonts.chrome)
            .foregroundStyle(PendingNetTheme.Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: PendingNetTheme.Metrics.controlHeight)
            .background(Capsule().fill(PendingNetTheme.Palette.surfaceMuted))
            .overlay(Capsule().stroke(PendingNetTheme.Palette.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct PendingEmptyState: View {
    let icon: String
    let title: String
    let detail: String?

    init(icon: String, title: String, detail: String? = nil) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(PendingNetTheme.Palette.accent)
            Text(title)
                .font(PendingNetTheme.Fonts.bodyEmphasized)
                .foregroundStyle(PendingNetTheme.Palette.ink)
            if let detail {
                Text(detail)
                    .font(PendingNetTheme.Fonts.caption)
                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }
}
