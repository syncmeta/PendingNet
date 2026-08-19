import SwiftUI

/// A transient toast notification.
///
/// The connection page used to show errors as inline banners inside the card.
/// Those banners only cleared when the next operation began, so a message that
/// described a one-time failure (or a condition that had since been fixed)
/// stayed on screen indefinitely. A toast inverts that: it pops up briefly,
/// then dismisses itself, and never lingers past the moment it's relevant.
struct PendingToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: PendingStatusPill.Kind
}

/// Holds the currently-visible toast. Anything that wants to surface a message
/// to the user calls `show`; the overlay (`PendingToastOverlay`) does the
/// drawing. Auto-dismisses after `lifetime`, so callers never have to remember
/// to clear it -- the whole point of replacing the inline banners.
@MainActor
final class PendingToastCenter: ObservableObject {
    @Published var current: PendingToast?

    /// Long enough to read a sentence, short enough not to feel stuck.
    private let lifetime: Duration = .seconds(4.2)
    private var dismissalTask: Task<Void, Never>?

    func show(_ text: String, kind: PendingStatusPill.Kind = .danger) {
        guard !text.isEmpty else { return }
        dismissalTask?.cancel()
        // Same text already on screen (e.g. two views both observing the same
        // published error): don't re-animate, just restart the timer so it
        // stays up a little longer rather than flashing.
        if current?.text != text {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                current = PendingToast(text: text, kind: kind)
            }
        }
        let token = current?.id
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self else { return }
            // Only clear if this is still the toast we armed the timer for -- a
            // newer `show` cancels this task, but guard the race anyway.
            guard self.current?.id == token else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.current = nil
            }
        }
    }

    func dismiss() {
        dismissalTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            current = nil
        }
    }
}

/// Floating toast rendered above a scene's content. Takes no space when
/// there's nothing to show. Tap to dismiss early.
///
/// The center is handed in explicitly rather than read with
/// `@EnvironmentObject`: this view is installed with `.overlay`, and overlay
/// content is a sibling of the modified view -- it only sees the environment
/// from *above* the modifier chain, so an `.environmentObject(toast)` written
/// earlier in that same chain never reaches it and the view traps on launch
/// with "No ObservableObject of type PendingToastCenter found". Passing it in
/// removes the ordering trap entirely.
struct PendingToastOverlay: View {
    @ObservedObject var center: PendingToastCenter

    var body: some View {
        if let toast = center.current {
            PendingToastView(toast: toast)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.dismiss() }
                .padding(.horizontal, PendingNetTheme.Metrics.gutter)
                .padding(.top, 12)
                .frame(maxWidth: PendingNetTheme.Metrics.readableWidth)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

private struct PendingToastView: View {
    let toast: PendingToast

    private var isDanger: Bool { toast.kind == .danger }

    private var icon: String {
        switch toast.kind {
        case .danger: "exclamationmark.circle.fill"
        case .success: "checkmark.circle.fill"
        case .neutral: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(toast.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(PendingNetTheme.Fonts.caption)
        .foregroundStyle(isDanger
            ? PendingNetTheme.Palette.danger
            : PendingNetTheme.Palette.success)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDanger
            ? PendingNetTheme.Palette.dangerBackground
            : PendingNetTheme.Palette.accentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((isDanger
                    ? PendingNetTheme.Palette.danger
                    : PendingNetTheme.Palette.accent).opacity(0.22),
                        lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}
