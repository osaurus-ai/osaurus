//
//  SharedHeaderComponents.swift
//  osaurus
//
//  Shared header components used by chat windows.
//  Ensures consistent styling and behavior across modes.
//

import AppKit
import SwiftUI

// MARK: - Header Action Button

/// An icon-only button for the toolbar. On macOS 26+ each icon sits on its
/// own circular Liquid Glass capsule; on earlier systems it relies on the
/// native toolbar item pill for its background and only renders the icon
/// with a hover color change.
struct HeaderActionButton: View {
    let icon: String
    let help: String
    /// Toggle state for buttons that open/close a panel: the icon takes the
    /// accent color and the circle gets a faint accent fill so the open
    /// pane's button reads as pressed. Default off keeps every plain action
    /// button unchanged.
    var isActive: Bool = false
    /// Small count shown at the top-trailing corner of the circle (e.g.
    /// files changed). Hidden when nil or zero; never changes the 28pt
    /// footprint so neighbours keep their spacing.
    var badge: Int? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(43, enabled: enabled, authoritative: true) }

    init(
        icon: String,
        help: String,
        isActive: Bool = false,
        badge: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.help = help
        self.isActive = isActive
        self.badge = badge
        self.action = action
    }

    private var isTinted: Bool { isHovered || isActive }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .glyphSize(12, weight: .medium)
                .foregroundColor(isTinted ? theme.text.link : theme.text.secondary)
                .frame(width: NativeComponentInspectionStyle.metric(43, "height", 28, theme), height: NativeComponentInspectionStyle.metric(43, "height", 28, theme))
                .componentInspectionSurface(43, background: isActive ? theme.selection.background : (isHovered ? theme.action.tertiary.hover.background : theme.action.tertiary.default.background), radius: 14, selected: isActive)
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .componentInspectionText(43, role: .caption, fallback: .micro, weight: 700, theme: theme)
                            .foregroundColor(theme.action.primary.default.foreground)
                            .padding(.horizontal, badge > 9 ? 4 : 0)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(theme.action.primary.default.background))
                            .overlay(Capsule().strokeBorder(theme.surface.canvas, lineWidth: theme.stroke.default))
                            .offset(x: 4, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.43.elements.layout.headerActionButton.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(43, "padding", 4, theme))).catalogLayoutTarget("component.library.43.elements.layout.headerActionButton.body.paddingX")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .help(Text(LocalizedStringKey(help), bundle: .module))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Close Button

struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(43, enabled: enabled, authoritative: true) }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .glyphSize(12, weight: .semibold)
                .foregroundColor(isHovered ? theme.status.error.foreground : theme.text.secondary)
                .frame(width: NativeComponentInspectionStyle.metric(43, "height", 28, theme), height: NativeComponentInspectionStyle.metric(43, "height", 28, theme))
                .componentInspectionSurface(43, background: .clear, radius: 14)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.43.elements.layout.closeButton.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(43, "padding", 4, theme))).catalogLayoutTarget("component.library.43.elements.layout.closeButton.body.paddingX")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .localizedHelp("Close window")
    }
}

// MARK: - Pin Button

struct PinButton: View {
    let windowId: UUID

    @State private var isHovered = false
    @State private var isPinned = false
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(43, enabled: enabled, authoritative: true) }

    var body: some View {
        Button {
            isPinned.toggle()
            ChatWindowManager.shared.setWindowPinned(id: windowId, pinned: isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .glyphSize(12, weight: .semibold)
                .foregroundColor(isPinned || isHovered ? theme.text.link : theme.text.secondary)
                .rotationEffect(.degrees(isPinned ? 0 : 45))
                .frame(width: NativeComponentInspectionStyle.metric(43, "height", 28, theme), height: NativeComponentInspectionStyle.metric(43, "height", 28, theme))
                .componentInspectionSurface(43, background: isHovered ? theme.action.tertiary.hover.background : theme.action.tertiary.default.background, radius: 14, selected: isPinned)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.43.elements.layout.pinButton.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(43, "padding", 4, theme))).catalogLayoutTarget("component.library.43.elements.layout.pinButton.body.paddingX")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .help(isPinned ? Text(localized: "Unpin from top") : Text(localized: "Pin to top"))
        .animation(theme.motion.springAnimation, value: isPinned)
    }
}

// MARK: - Agent Picker Keyboard Controller

/// Drives arrow-key / Enter / Esc navigation for the agent picker popover.
/// Held as a `@StateObject` so the long-lived key-monitor closure captures a
/// stable class reference instead of a stale `View` value — mirroring the
/// coordinator pattern the model picker uses.
@MainActor
final class AgentPickerKeyboardController: ObservableObject {
    /// Index (into the popover's flattened item list) the user has arrowed to.
    @Published var highlightedIndex: Int?

    private var monitor: Any?
    private var itemCount: Int = 0
    private var onActivate: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    /// Index to resume arrow-key navigation from on the first key press, set to
    /// the current selection. Held separately from `highlightedIndex` so opening
    /// the popover doesn't paint a focus border on the selected row (it's already
    /// marked by its checkmark) — the highlight only appears once the user
    /// actually navigates.
    private var pendingStartIndex: Int?

    /// Begin monitoring keys for an open popover. Safe to call repeatedly; the
    /// monitor is installed once and the callbacks/count are refreshed.
    func start(
        itemCount: Int,
        initialIndex: Int?,
        onActivate: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.itemCount = itemCount
        // Start with nothing highlighted so the selected row isn't bordered on
        // open; remember where to resume arrow-key navigation from.
        self.highlightedIndex = nil
        self.pendingStartIndex = initialIndex
        self.onActivate = onActivate
        self.onDismiss = onDismiss

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125:  // down arrow
                self.move(by: 1)
                return nil
            case 126:  // up arrow
                self.move(by: -1)
                return nil
            case 36, 76:  // return / numpad enter
                // Activate the highlighted row, or — if the user hasn't arrowed
                // yet — the current selection (so open + Enter confirms it).
                if let index = self.highlightedIndex ?? self.pendingStartIndex {
                    self.onActivate?(index)
                    return nil
                }
                return event
            case 53:  // escape
                self.onDismiss?()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        highlightedIndex = nil
        pendingStartIndex = nil
        onActivate = nil
        onDismiss = nil
    }

    private func move(by offset: Int) {
        guard itemCount > 0 else { return }
        if let current = highlightedIndex {
            highlightedIndex = max(0, min(itemCount - 1, current + offset))
        } else if let resume = pendingStartIndex {
            // First arrow press after open: continue from the current selection.
            highlightedIndex = max(0, min(itemCount - 1, resume + offset))
            pendingStartIndex = nil
        } else {
            highlightedIndex = offset > 0 ? 0 : itemCount - 1
        }
    }
}
