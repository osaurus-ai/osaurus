//
//  ChatSelectionControls.swift
//  osaurus
//
//  The tick box on selectable chat rows and the bar that acts on the
//  ticked chats, shared by the sidebar and the All chats page.
//

import SwiftUI

extension ThemeProtocol {
    /// The rail scopes its theme to the sidebar family (its accent, its
    /// row radius as `radius.small`, and a raised surface equal to its own
    /// background). Selection controls read the window's theme instead, so
    /// a ticked chat and the bar look the same in the rail and on the page.
    var unscopedForSelection: any ThemeProtocol {
        (self as? CatalogResolvedTheme)?.base ?? self
    }
}

/// A small square that fits a row's 24-point icon column, filled with the
/// accent while ticked. The whole column is the hit target.
struct ChatSelectionCheckbox: View {
    let isChecked: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.theme) private var environmentTheme
    @State private var isHovered = false

    static let side: CGFloat = 14

    private var theme: any ThemeProtocol { environmentTheme.unscopedForSelection }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.radius.small, Self.side / 4), style: .continuous)
        let accent = theme.action.primary.default
        Button(action: action) {
            shape
                .fill(isChecked ? accent.background : Color.clear)
                .overlay(
                    shape.strokeBorder(
                        isChecked ? accent.background : (isHovered ? theme.text.primary : theme.text.tertiary),
                        lineWidth: theme.stroke.default)
                )
                .overlay {
                    if isChecked {
                        Image(systemName: "checkmark")
                            .glyphSize(.micro, weight: .bold)
                            .foregroundStyle(accent.foreground)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .frame(width: NavigatorRowMetrics.iconColumn, height: NavigatorRowMetrics.iconColumn)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(theme.motion.quick, value: isChecked)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}

/// Acts on the ticked chats. The sidebar keeps it narrow: the count, icon
/// buttons for Archive and Delete, and Done. The page has room for Select
/// all, Pin and labelled actions, and closes with ×.
struct ChatBatchBar: View {
    enum Placement { case sidebar, page }

    let placement: Placement
    let selectedCount: Int
    var allPinned = false
    var allArchived = false
    /// The page offers "Select all N" while some of the chats it shows are
    /// not ticked.
    var selectAllCount: Int?
    var onSelectAll: () -> Void = {}
    var onPin: () -> Void = {}
    let onArchive: () -> Void
    let onDelete: () -> Void
    /// Nil hides Done / ×: the page shows the bar for Select all while a
    /// filter narrows the list, before selection mode starts.
    let onDone: (() -> Void)?

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.unscopedForSelection }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        HStack(spacing: theme.space.s4) {
            label
            if let selectAllCount {
                SettingsButton(.tertiary, L("Select all \(selectAllCount)"), size: .compact, verbatim: true, action: onSelectAll)
            }
            Spacer(minLength: theme.space.s8)
            if selectedCount > 0 {
                switch placement {
                case .sidebar: sidebarActions
                case .page: pageActions
                }
            }
            if let onDone {
                switch placement {
                case .sidebar:
                    SettingsButton(.tertiary, "Done", size: .compact, action: onDone)
                case .page:
                    SettingsIconButton("xmark", help: "Clear selection", size: .compact, role: .tertiary, action: onDone)
                }
            }
        }
        .padding(.leading, theme.space.s12)
        .padding(.trailing, theme.space.s4)
        .padding(.vertical, theme.space.s4)
        .background(shape.fill(theme.surface.raised))
        .overlay(shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
        .environment(\.theme, theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Selected chats", bundle: .module))
    }

    private var label: some View {
        Text(verbatim: selectedCount == 0 ? L("Tick chats to select") : L("\(selectedCount) selected"))
            .textStyle(.label, weight: 600)
            .monospacedDigit()
            .foregroundStyle(selectedCount == 0 ? theme.text.secondary : theme.text.primary)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var sidebarActions: some View {
        SettingsIconButton(
            allArchived ? "tray.and.arrow.up" : "archivebox",
            help: allArchived ? "Unarchive" : "Archive",
            size: .compact, role: .tertiary, action: onArchive)
        SettingsIconButton("trash", help: "Delete", size: .compact, isDestructive: true, role: .tertiary, action: onDelete)
    }

    @ViewBuilder private var pageActions: some View {
        SettingsButton(.tertiary, allPinned ? "Unpin" : "Pin", icon: allPinned ? "pin.slash" : "pin", size: .compact, action: onPin)
        SettingsButton(
            .tertiary, allArchived ? "Unarchive" : "Archive",
            icon: allArchived ? "tray.and.arrow.up" : "archivebox", size: .compact, action: onArchive)
        SettingsButton(.destructive, "Delete", icon: "trash", size: .compact, action: onDelete)
    }
}
