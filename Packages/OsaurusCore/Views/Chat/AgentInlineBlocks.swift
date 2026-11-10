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
//  appear. The chrome is an opaque `surface.raised` card with the
//  `elevation.overlay` recipe (no component glass). The Todo
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
    static let dismissButtonSize: CGFloat = 20
    static let pinIconRotationDegrees: Double = 30
    static let hoverOutDebounce: Duration = .milliseconds(50)
}

// MARK: - Floating chrome backing

/// Opaque floating-chrome surface: semantic raised surface + optional status
/// tint laid over it + border + the theme's overlay elevation. Drives the
/// floating-chrome look for both inline blocks (no component glass).
private struct FloatingChromeSurface: View {
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(35, authoritative: true) }
    let tint: Color
    let borderColor: Color
    var highlight: Color? = nil
    var surfacePart = "todo"

    var body: some View {
        ZStack {
            #if OSAURUS_DESIGN_SYSTEM
            shape.fill(highlight ?? AgentContentSurfaceAssignments.color(35, surfacePart, theme))
                .nativeCatalogTarget([AgentContentSurfaceAssignments.key(35, surfacePart)], surfacePart == "completion" ? "Agent completion card" : "Agent task progress")
            #else
            shape.fill(highlight ?? theme.surface.raised)
            #endif
            #if !OSAURUS_DESIGN_SYSTEM
            shape.fill(tint)
            #endif
            shape.strokeBorder(borderColor, lineWidth: theme.stroke.default)
        }
        .themeElevation(theme.elevation.overlay)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AgentProgressInspectionStyle.metric("radius", Layout.cornerRadius, theme), style: .continuous)
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(35, authoritative: true) }
    @State private var isHovered = false
    @State private var isPinned = false
    @State private var debouncer = HoverDebouncer()

    private var isExpanded: Bool { isHovered || isPinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pillRow
            if isExpanded { stepRows }
        }
        .frame(minHeight: AgentProgressInspectionStyle.metric("height", 0, theme))
        .background(
            FloatingChromeSurface(
                tint: .clear,
                borderColor: theme.border.default,
                highlight: AgentProgressInspectionStyle.highlight(hovered: isHovered, pinned: isPinned, theme: theme)
            )
        )
        .padding(.horizontal, Layout.outerHorizontalMargin)
        .environment(\.theme, theme)
        .animation(theme.motion.springAnimation, value: isExpanded)
        .animation(theme.motion.springAnimation, value: todo.items.map(\.isDone))
        .chromeHover(
            isHovered: $isHovered,
            debouncer: debouncer,
            animation: theme.motion.springAnimation
        )
    }

    private var pillRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.pillRow.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", Layout.interItemSpacing, theme))) {
            Image(systemName: "checklist")
                .glyphSize(15)
                .foregroundColor(theme.text.secondary)

            Text(localized: "Todo")
                .agentProgressText(.label, fallback: .body, weight: 500, theme: theme)
                .foregroundColor(theme.text.primary)

            if todo.totalCount > 0 {
                Text("\(todo.doneCount)/\(todo.totalCount)")
                    .agentProgressText(.caption, fallback: .caption, theme: theme)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer()

            stateIcon
        }.catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.pillRow.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.pillRow.paddingX", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.contentPaddingH, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.pillRow.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.pillRow.paddingY", inheriting: isExpanded ? AgentProgressInspectionStyle.metric("padding", Layout.expandedPaddingV, theme) : AgentProgressInspectionStyle.metric("padding", Layout.pillPaddingV, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.pillRow.paddingY")
        .contentShape(Rectangle())
        .onTapGesture(perform: togglePin)
        .help(isPinned ? Text(localized: "Unpin") : Text(localized: "Click to keep open"))
    }

    private var stateIcon: some View {
        let name = isPinned ? "pin.fill" : (isExpanded ? "chevron.up" : "chevron.down")
        return Image(systemName: name)
            .glyphSize(10, weight: .bold)
            .foregroundColor(isPinned ? theme.text.primary : theme.text.tertiary)
            .rotationEffect(.degrees(isPinned ? Layout.pinIconRotationDegrees : 0))
    }

    @ViewBuilder
    private var stepRows: some View {
        if todo.items.isEmpty {
            Text(localized: "No checklist items parsed.")
                .agentProgressText(.caption, fallback: .caption, theme: theme)
                .foregroundColor(theme.text.tertiary)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.contentPaddingH, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX")
                .padding(.bottom, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingY", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.stepRowsPaddingV, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingY")
        } else {
            Rectangle().fill(theme.border.default)
                .frame(height: AgentProgressInspectionStyle.metric("borderWidth", ThemeStrokes.hairline(forBackingScale: NSScreen.main?.backingScaleFactor ?? 2), theme))
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX2", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.contentPaddingH, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX2")
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.verticalGap", inheriting: AgentProgressInspectionStyle.metric("gap", Layout.stepRowSpacing, theme))) {
                ForEach(todo.items, content: todoItemRow)
            }.catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.verticalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX3", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.contentPaddingH, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingX3")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingY2", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.stepRowsPaddingV, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.stepRows.paddingY2")
        }
    }

    private func todoItemRow(_ item: AgentTodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.inlineTodoBlock.todoItemRow.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", Layout.interItemSpacing, theme))) {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .glyphSize(15)
                .foregroundColor(item.isDone ? theme.status.success.foreground : theme.text.tertiary)
                .frame(width: Layout.stepIconWidth, alignment: .center)

            Text(item.text)
                .agentProgressText(.body, fallback: .body, theme: theme)
                .foregroundColor(item.isDone ? theme.text.tertiary : theme.text.primary)
                .strikethrough(item.isDone, color: theme.text.tertiary)
        }.catalogLayoutTarget("component.library.35.elements.layout.inlineTodoBlock.todoItemRow.horizontalGap")
    }

    private func togglePin() {
        withAnimation(theme.motion.springAnimation) {
            isPinned.toggle()
        }
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
    let isBlocked: Bool
    var onDismiss: () -> Void

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(35, authoritative: true) }

    private var statusColor: Color {
        isBlocked ? theme.status.warning.foreground : theme.status.success.foreground
    }

    var body: some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.inlineCompleteBlock.body.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", Layout.bannerIconSpacing, theme))) {
            Image(systemName: isBlocked ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundColor(statusColor)
                .padding(.top, Layout.bannerIconTopOffset)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.inlineCompleteBlock.body.verticalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 4, theme))) {
                Text(localized: isBlocked ? "Blocked" : "Done")
                    .agentProgressText(.heading, fallback: .caption, weight: 600, theme: theme)
                    .foregroundColor(statusColor)
                    .textCase(.uppercase)

                Text(summary)
                    .agentProgressText(.body, fallback: .body, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }.catalogLayoutTarget("component.library.35.elements.layout.inlineCompleteBlock.body.verticalGap")

            Spacer(minLength: AgentProgressInspectionStyle.metric("gap", Layout.interItemSpacing, theme))

            DismissButton(action: dismiss)
                .padding(.top, Layout.dismissButtonTopOffset)
        }.catalogLayoutTarget("component.library.35.elements.layout.inlineCompleteBlock.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineCompleteBlock.body.paddingX", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.contentPaddingH, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineCompleteBlock.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.inlineCompleteBlock.body.paddingY", inheriting: AgentProgressInspectionStyle.metric("padding", Layout.bannerPaddingV, theme))).catalogLayoutTarget("component.library.35.elements.layout.inlineCompleteBlock.body.paddingY")
        .frame(minHeight: AgentProgressInspectionStyle.metric("height", 0, theme))
        .background(
            FloatingChromeSurface(
                tint: statusColor.opacity(0.10),
                borderColor: theme.assignedColor(AgentProgressInspectionStyle.key + "border", fallback: statusColor.opacity(0.30)),
                surfacePart: "completion"
            )
        )
        .padding(.horizontal, Layout.outerHorizontalMargin)
        .environment(\.theme, theme)
    }

    /// Eased fade reads as a clean "this is gone" — spring would
    /// overshoot the alpha curve and feel jittery for a pure
    /// opacity-only transition.
    private func dismiss() {
        withAnimation(theme.motion.standard) {
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(35, authoritative: true) }
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .glyphSize(10, weight: .bold)
                .foregroundColor(isHovered ? theme.text.primary : theme.text.tertiary)
                .frame(width: AgentProgressInspectionStyle.metric("height", Layout.dismissButtonSize, theme), height: AgentProgressInspectionStyle.metric("height", Layout.dismissButtonSize, theme))
                .background(
                    Circle().fill(
                        isHovered
                            ? theme.surface.hover
                            : theme.assignedColor(AgentProgressInspectionStyle.key + "background", fallback: .clear)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .localizedHelp("Dismiss")
    }
}
