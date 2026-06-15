//
//  AgentInlineBlocks.swift
//  osaurus
//
//  Floating UI chrome for the unified Chat agent loop:
//
//    - `InlineTodoBlock`     read-only checklist parsed from the agent's
//                            most recent `todo(markdown)` call. Renders
//                            as a compact pill that hover-peeks expanded
//                            and pins on click.
//    - `InlineCompleteBlock` "Task done" banner shown when the agent
//                            calls `complete(summary)`. Always rendered
//                            in full; the user dismisses with the `×`
//                            button (or implicitly by sending the next
//                            message).
//
//  Both live in a top-anchored overlay over the message thread (see
//  `ChatView.messageThread`) so the thread doesn't shrink when they
//  appear. The chrome uses `.regularMaterial` for a translucent backing
//  so conversation content stays visible behind the banner. The Todo
//  pill reserves a small inset on the thread so the topmost message
//  isn't hidden; the Done banner overlays content (it's a transient
//  notification, not a layout fixture).
//
//  `clarify` used to live here too (`InlineClarifyBlock`), but it has
//  been promoted to a bottom-pinned overlay (`ClarifyPromptOverlay`)
//  that mounts through the shared `PromptQueue` alongside secret
//  prompts. See `ClarifyPromptOverlay.swift` and `PromptQueue.swift`.
//

import SwiftUI

// MARK: - Public metrics

/// Approximate collapsed-pill height for `InlineTodoBlock`. Used by
/// `ChatView` to inset the message thread so the topmost message isn't
/// permanently hidden behind the floating chrome. Kept conservative —
/// the actual rendered pill height varies slightly with theme font, but
/// a small over-reservation is preferable to having the first line
/// clipped. `InlineCompleteBlock` does NOT contribute to the inset; it
/// renders as a translucent banner that overlays content beneath the
/// Todo pill until the user dismisses it.
enum AgentInlineBlockMetrics {
    static let collapsedPillHeight: CGFloat = 38
    static let stackSpacing: CGFloat = 6
}

// MARK: - Internal layout constants

private enum Layout {
    static let cornerRadius: CGFloat = 14
    static let outerHorizontalMargin: CGFloat = 16
    static let contentPaddingH: CGFloat = 12
    static let pillPaddingV: CGFloat = 8
    static let expandedPaddingV: CGFloat = 10
    static let bannerPaddingV: CGFloat = 12
    static let interItemSpacing: CGFloat = 8
    static let bannerIconSpacing: CGFloat = 10
    static let stepRowSpacing: CGFloat = 6
    static let stepRowsPaddingV: CGFloat = 10
    static let stepIconWidth: CGFloat = 16
    static let bannerIconTopOffset: CGFloat = 2
    static let dismissButtonTopOffset: CGFloat = 1
    static let smallIconSizeDelta: CGFloat = -2  // delta from caption size; used by chevron + xmark
    static let dismissButtonSize: CGFloat = 20
    static let dismissHoverFillOpacity: Double = 0.45
    static let glassShadowRadius: CGFloat = 12
    static let glassShadowYOffset: CGFloat = 3
    static let glassShadowOpacity: Double = 0.10
    static let pinIconRotationDegrees: Double = 30
    static let dismissFadeDuration: Double = 0.22
    static let hoverHighlightDuration: Double = 0.15
    static let hoverOutDebounce: Duration = .milliseconds(50)
}

// MARK: - Glass backing

/// Translucent surface stack: `.regularMaterial` + theme-tinted overlay +
/// soft border + drop shadow. Drives the floating-chrome look for both
/// inline blocks.
private struct FloatingGlassSurface: View {
    let tint: Color
    let borderColor: Color

    var body: some View {
        ZStack {
            shape.fill(.regularMaterial)
            shape.fill(tint)
            shape.strokeBorder(borderColor, lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(Layout.glassShadowOpacity),
            radius: Layout.glassShadowRadius,
            x: 0,
            y: Layout.glassShadowYOffset
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
    }
}

// MARK: - Todo hover plumbing

/// Delays the hover-out flip by ~50ms so the cursor crossing the pill's
/// edge during the spring expansion doesn't cause a visible flicker.
/// Cancels any pending hover-out when hover-in arrives. Used only by
/// `InlineTodoBlock` (Done has no hover behavior).
@MainActor
private final class HoverDebouncer {
    private var task: Task<Void, Never>?

    func setHovered(_ hovering: Bool, apply: @escaping @MainActor (Bool) -> Void) {
        task?.cancel()
        if hovering {
            apply(true)
            return
        }
        task = Task { @MainActor in
            try? await Task.sleep(for: Layout.hoverOutDebounce)
            guard !Task.isCancelled else { return }
            apply(false)
        }
    }
}

extension View {
    /// Wires `onHover` with a small hover-out debounce, animating the
    /// hover-state binding inside the supplied animation. Used by the
    /// Todo pill to avoid flicker when the cursor crosses the pill's
    /// expanding edge.
    fileprivate func chromeHover(
        isHovered: Binding<Bool>,
        debouncer: HoverDebouncer,
        animation: Animation
    ) -> some View {
        onHover { hovering in
            debouncer.setHovered(hovering) { value in
                withAnimation(animation) {
                    isHovered.wrappedValue = value
                }
            }
        }
    }
}

// MARK: - Todo

struct InlineTodoBlock: View {
    let todo: AgentTodo

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isPinned = false
    @State private var debouncer = HoverDebouncer()

    private var isExpanded: Bool { isHovered || isPinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pillRow
            if isExpanded { stepRows }
        }
        .background(
            FloatingGlassSurface(
                tint: theme.secondaryBackground.opacity(0.25),
                borderColor: theme.primaryBorder.opacity(0.35)
            )
        )
        .padding(.horizontal, Layout.outerHorizontalMargin)
        .animation(theme.springAnimation(), value: isExpanded)
        .animation(theme.springAnimation(), value: todo.items.map(\.isDone))
        .chromeHover(
            isHovered: $isHovered,
            debouncer: debouncer,
            animation: theme.springAnimation()
        )
    }

    private var pillRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.interItemSpacing) {
            Image(systemName: "checklist")
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .foregroundColor(theme.accentColor)

            Text(localized: "Todo")
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(theme.primaryText)

            if todo.totalCount > 0 {
                Text("\(todo.doneCount)/\(todo.totalCount)")
                    .font(theme.font(size: CGFloat(theme.captionSize)))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            stateIcon
        }
        .padding(.horizontal, Layout.contentPaddingH)
        .padding(.vertical, isExpanded ? Layout.expandedPaddingV : Layout.pillPaddingV)
        .contentShape(Rectangle())
        .onTapGesture(perform: togglePin)
        .help(isPinned ? Text(localized: "Unpin") : Text(localized: "Click to keep open"))
    }

    private var stateIcon: some View {
        let name = isPinned ? "pin.fill" : (isExpanded ? "chevron.up" : "chevron.down")
        return Image(systemName: name)
            .font(theme.font(size: smallIconSize, weight: .bold))
            .foregroundColor(isPinned ? theme.accentColor : theme.tertiaryText)
            .rotationEffect(.degrees(isPinned ? Layout.pinIconRotationDegrees : 0))
    }

    @ViewBuilder
    private var stepRows: some View {
        if todo.items.isEmpty {
            Text(localized: "No checklist items parsed.")
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, Layout.contentPaddingH)
                .padding(.bottom, Layout.stepRowsPaddingV)
        } else {
            Divider().padding(.horizontal, Layout.contentPaddingH)
            VStack(alignment: .leading, spacing: Layout.stepRowSpacing) {
                ForEach(todo.items, content: todoItemRow)
            }
            .padding(.horizontal, Layout.contentPaddingH)
            .padding(.vertical, Layout.stepRowsPaddingV)
        }
    }

    private func todoItemRow(_ item: AgentTodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.interItemSpacing) {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .foregroundColor(item.isDone ? theme.successColor : theme.tertiaryText)
                .frame(width: Layout.stepIconWidth, alignment: .center)

            Text(item.text)
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .foregroundColor(item.isDone ? theme.tertiaryText : theme.primaryText)
                .strikethrough(item.isDone, color: theme.tertiaryText)
        }
    }

    private func togglePin() {
        withAnimation(theme.springAnimation()) {
            isPinned.toggle()
        }
    }

    private var smallIconSize: CGFloat {
        CGFloat(theme.captionSize) + Layout.smallIconSizeDelta
    }
}

// MARK: - Complete

/// "Task done" banner. Rendered when the agent calls `complete(summary)`
/// and the engine ends the iteration loop. Always shown in full — not
/// collapsible. The user dismisses via the `×` button (or implicitly by
/// sending the next message, which clears `lastCompletionSummary`
/// upstream in `ChatSession`). Designed to feel like a translucent
/// notification banner that overlays the chat content; the user can
/// dismiss it to read what's underneath.
struct InlineCompleteBlock: View {
    let summary: String
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: Layout.bannerIconSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(theme.successColor)
                .padding(.top, Layout.bannerIconTopOffset)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized: "Done")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.successColor)
                    .textCase(.uppercase)

                Text(summary)
                    .font(theme.font(size: CGFloat(theme.bodySize)))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Layout.interItemSpacing)

            DismissButton(action: dismiss)
                .padding(.top, Layout.dismissButtonTopOffset)
        }
        .padding(.horizontal, Layout.contentPaddingH)
        .padding(.vertical, Layout.bannerPaddingV)
        .background(
            FloatingGlassSurface(
                tint: theme.successColor.opacity(0.10),
                borderColor: theme.successColor.opacity(0.30)
            )
        )
        .padding(.horizontal, Layout.outerHorizontalMargin)
    }

    /// Eased fade reads as a clean "this is gone" — spring would
    /// overshoot the alpha curve and feel jittery for a pure
    /// opacity-only transition.
    private func dismiss() {
        withAnimation(.easeOut(duration: Layout.dismissFadeDuration)) {
            onDismiss()
        }
    }
}

// MARK: - Dismiss button

/// Small circular hover-highlighted button used by `InlineCompleteBlock`.
/// Keeps its hover state local so the parent block doesn't need an
/// extra `@State` flag.
private struct DismissButton: View {
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(
                    theme.font(
                        size: CGFloat(theme.captionSize) + Layout.smallIconSizeDelta,
                        weight: .bold
                    )
                )
                .foregroundColor(isHovered ? theme.primaryText : theme.tertiaryText)
                .frame(width: Layout.dismissButtonSize, height: Layout.dismissButtonSize)
                .background(
                    Circle().fill(
                        isHovered
                            ? theme.primaryBorder.opacity(Layout.dismissHoverFillOpacity)
                            : .clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: Layout.hoverHighlightDuration)) {
                isHovered = hovering
            }
        }
        .localizedHelp("Dismiss")
    }
}
