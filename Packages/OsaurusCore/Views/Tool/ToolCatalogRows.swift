//
//  ToolCatalogRows.swift
//  osaurus
//
//  Reusable row-level building blocks for the Tools catalog: tool rows,
//  the enable switch, the permission-behavior menu, status pills, section
//  headers, filter menus, and shared card chrome. Split out of
//  ToolsManagerView so the catalog view stays a coordinator and other
//  surfaces (PluginsView, cards) can share the same controls.
//

import SwiftUI

// MARK: - Tool Policy Style

/// Shared helpers for tool permission-behavior display.
enum ToolPolicyStyle {
    static func icon(for policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: "sparkles"
        case .ask: "questionmark.circle"
        case .deny: "xmark.circle"
        }
    }

    static func color(for policy: ToolPermissionPolicy, theme: ThemeProtocol) -> Color {
        switch policy {
        case .auto: theme.accentColor
        case .ask: .orange
        case .deny: theme.errorColor
        }
    }

    /// Full menu-option label, in plain language rather than the raw
    /// auto/ask/deny vocabulary.
    static func title(for policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: L("Allow automatically")
        case .ask: L("Ask before running")
        case .deny: L("Block")
        }
    }

    /// Compact label for the collapsed chip on tool rows.
    static func compactTitle(for policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: L("Allowed")
        case .ask: L("Ask first")
        case .deny: L("Blocked")
        }
    }
}

// MARK: - Menu Pill

/// Button style that wraps a menu label in a capsule without touching the
/// label's own layout. A custom `ButtonStyle` passes `configuration.label`
/// through verbatim, so the label's spacing/padding survive — unlike
/// `.bordered`, which re-lays out the label and ignores its `HStack` spacing.
private struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let stroke: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// A pill-shaped dropdown whose visible chrome is a fully custom `label`. It is
/// a real `Menu` (so clicking works) rendered as a button with `PillButtonStyle`
/// and the system menu indicator hidden — the label owns all spacing, padding,
/// background, and colors.
struct MenuPill<MenuContent: View, Label: View>: View {
    let fill: Color
    let stroke: Color
    private let menuContent: () -> MenuContent
    private let label: () -> Label

    init(
        fill: Color,
        stroke: Color,
        @ViewBuilder menuContent: @escaping () -> MenuContent,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.fill = fill
        self.stroke = stroke
        self.menuContent = menuContent
        self.label = label
    }

    var body: some View {
        Menu {
            menuContent()
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(fill: fill, stroke: stroke))
        .menuIndicator(.hidden)
    }
}

// MARK: - Tool Policy Menu

/// Reusable permission-behavior selector menu for a single tool entry.
struct ToolPolicyMenu: View {
    @Environment(\.theme) private var theme
    let toolName: String
    let info: ToolRegistry.ToolPolicyInfo
    let onChange: () -> Void

    private var color: Color {
        ToolPolicyStyle.color(for: info.effectivePolicy, theme: theme)
    }

    var body: some View {
        MenuPill(fill: color.opacity(0.14), stroke: color.opacity(0.22)) {
            ForEach([ToolPermissionPolicy.auto, .ask, .deny], id: \.self) { policy in
                Button {
                    ToolRegistry.shared.setPolicy(policy, for: toolName)
                    onChange()
                } label: {
                    HStack {
                        Image(systemName: ToolPolicyStyle.icon(for: policy))
                        Text(ToolPolicyStyle.title(for: policy))
                        if policy == info.effectivePolicy {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: ToolPolicyStyle.icon(for: info.effectivePolicy))
                    .font(.system(size: 9, weight: .semibold))
                Text(ToolPolicyStyle.compactTitle(for: info.effectivePolicy))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        }
        .fixedSize()
        .help(Text("Choose whether this tool runs automatically, asks first, or is blocked", bundle: .module))
        .accessibilityLabel(
            Text(
                "Permission behavior for \(toolName): \(ToolPolicyStyle.title(for: info.effectivePolicy))",
                bundle: .module
            )
        )
    }
}

// MARK: - Tool Enable Toggle

/// Reusable switch for turning a tool on or off.
struct ToolEnableToggle: View {
    let entry: ToolRegistry.ToolEntry
    let onChange: () -> Void

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { entry.enabled },
                set: { newValue in
                    ToolRegistry.shared.setEnabled(newValue, for: entry.name)
                    onChange()
                }
            )
        )
        .toggleStyle(SwitchToggleStyle())
        .labelsHidden()
        .scaleEffect(0.85)
        .help(Text("Turn this tool on or off", bundle: .module))
        .accessibilityLabel(Text("Enable \(entry.name)", bundle: .module))
    }
}

// MARK: - Catalog Status Pill

/// Plain-language status pill shown on catalog rows: Ready, Off, or Needs
/// attention. Hovering reveals the human-readable availability detail.
struct ToolCatalogStatusPill: View {
    @Environment(\.theme) private var theme
    let status: ToolCatalogStatus
    let detail: String

    private var tint: Color {
        switch status {
        case .ready: theme.successColor
        case .off: theme.secondaryText
        case .needsAttention: theme.warningColor
        }
    }

    var body: some View {
        Text(status.displayLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .help(Text(detail))
            .accessibilityLabel(Text("Status: \(status.displayLabel). \(detail)", bundle: .module))
    }
}

// MARK: - Tool Section Header

/// Group header used inside the catalog list, with an explicit tool count so
/// the screen carries its own numbers instead of the tab bar.
struct ToolSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.tertiaryBackground))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A source header that keeps large inventories out of the default scan while
/// preserving a one-click path to every tool.
struct ToolSectionDisclosureHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.tertiaryBackground))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.45))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("\(title), \(count) tools", bundle: .module))
        .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed", bundle: .module))
    }
}

// MARK: - Show All Tools Button

/// Disclosure control that toggles a capped tool group between its first
/// `toolGroupRenderCapValue` rows and the full list.
struct ShowAllToolsButton: View {
    @Environment(\.theme) private var theme
    let hiddenCount: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                if isExpanded {
                    Text("Show fewer", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Show \(hiddenCount) more", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                Spacer()
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Filter Menu

protocol ToolCatalogFilterOption: Identifiable, Hashable {
    var title: String { get }
}

extension ToolCatalogStatusFilter: ToolCatalogFilterOption {}
extension ToolCatalogSourceFilter: ToolCatalogFilterOption {}

/// Compact dropdown filter used by the catalog toolbar and the advanced
/// diagnostics section.
struct ToolFilterMenu<Option: ToolCatalogFilterOption>: View {
    @Environment(\.theme) private var theme

    let icon: String
    let accessibilityTitle: String
    let options: [Option]
    @Binding var selection: Option

    var body: some View {
        MenuPill(fill: theme.tertiaryBackground, stroke: theme.inputBorder) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        if option == selection {
                            Image(systemName: "checkmark")
                        }
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(selection.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .fixedSize()
        .accessibilityLabel(Text("\(accessibilityTitle): \(selection.title)"))
    }
}

// MARK: - Card Chrome

/// Rounded card chrome whose hover-reactive border/shadow live in their own
/// small subview. Used as a `.background(...)` so hovering a card re-renders
/// only this lightweight view instead of invalidating the card's content
/// body — important when the mouse sweeps across a list of cards.
struct HoverableCardBackground: View {
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.shadowColor.opacity(theme.shadowOpacity),
                radius: theme.cardShadowRadius,
                x: 0,
                y: theme.cardShadowY
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - Runtime Managed Tool Entry Row

/// Read-only operational tool row (built-in, native, folder, and sandbox
/// execution tools). No enable switch — these are managed by the runtime —
/// but permission behavior stays adjustable.
struct RuntimeManagedToolEntryRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let badge: String
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var status: ToolCatalogStatus = .ready
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = policyInfo else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ToolRowIcon(systemName: "terminal", showsWarning: hasMissingSystemPermissions)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: 8) {
                ToolSourceBadge(title: badge)
                Spacer(minLength: 8)
            }
            .padding(.leading, 38)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var policyMenu: some View {
        if let info = policyInfo {
            ToolPolicyMenu(toolName: entry.name, info: info, onChange: onChange)
        }
    }
}

// MARK: - Tool Entry Row (shared with plugin/custom cards)

struct ToolEntryRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    var sourceLabel: String? = nil
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var status: ToolCatalogStatus = .ready
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = policyInfo else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ToolRowIcon(systemName: "function", showsWarning: hasMissingSystemPermissions)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: 8) {
                if let sourceLabel {
                    ToolSourceBadge(title: sourceLabel)
                }
                Spacer(minLength: 8)
                ToolEnableToggle(entry: entry, onChange: onChange)
            }
            .padding(.leading, 38)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)

                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var policyMenu: some View {
        if let info = policyInfo {
            ToolPolicyMenu(toolName: entry.name, info: info, onChange: onChange)
        }
    }
}

// MARK: - Remote Tool Row

/// Row for a tool provided by a connection. Strips the provider prefix from
/// the display name so users see the tool as the service names it.
struct RemoteToolRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let providerName: String
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var status: ToolCatalogStatus = .ready
    let onChange: () -> Void

    private var displayName: String {
        let safeProviderName =
            providerName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let prefix = "\(safeProviderName)_"
        if entry.name.hasPrefix(prefix) {
            return String(entry.name.dropFirst(prefix.count))
        }
        return entry.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ToolRowIcon(systemName: "function", showsWarning: false)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: 8) {
                ToolSourceBadge(title: providerName)
                Spacer(minLength: 8)
                ToolEnableToggle(entry: entry, onChange: onChange)
            }
            .padding(.leading, 38)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var policyMenu: some View {
        if let info = policyInfo {
            ToolPolicyMenu(toolName: entry.name, info: info, onChange: onChange)
        }
    }
}

struct ToolSourceBadge: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.tertiaryBackground))
            .help(Text("Where this tool comes from", bundle: .module))
    }
}

// MARK: - Row Icon

/// Small leading icon for tool rows, with an inline warning overlay when the
/// tool is missing a system permission.
private struct ToolRowIcon: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let showsWarning: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    showsWarning
                        ? theme.warningColor.opacity(0.1) : theme.accentColor.opacity(0.08)
                )
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(showsWarning ? theme.warningColor : theme.accentColor)

            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(theme.warningColor)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 28, height: 28)
    }
}
