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
        case .auto: theme.status.success.foreground
        case .ask: theme.status.warning.foreground
        case .deny: theme.status.error.foreground
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

/// Button style that wraps a menu label in kit chrome without touching the
/// label's own layout. A custom `ButtonStyle` passes `configuration.label`
/// through verbatim, so the label's spacing/padding survive — unlike
/// `.bordered`, which re-lays out the label and ignores its `HStack` spacing.
/// A compact dropdown on the kit's compact button chrome, with the system
/// menu indicator hidden so the label can draw its own chevron.
struct MenuPill<MenuContent: View, Label: View>: View {
    private let menuContent: () -> MenuContent
    private let label: () -> Label

    init(
        @ViewBuilder menuContent: @escaping () -> MenuContent,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.menuContent = menuContent
        self.label = label
    }

    var body: some View {
        SettingsActionMenu(accessibilityLabel: L("Tool options")) {
            menuContent()
        } label: {
            label()
        }
        .menuStyle(.button)
        .assignedSettingsButtonStyle(.secondary, size: .compact)
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

    /// Send / delete tools ask on every call no matter what is configured
    /// (`ToolRegistry.execute` forces `.ask`), so offering Auto here would
    /// be a switch that does nothing.
    private var offeredPolicies: [ToolPermissionPolicy] {
        ToolRegistry.shared.requiresPerCallApproval(toolName) ? [.ask, .deny] : [.auto, .ask, .deny]
    }

    var body: some View {
        MenuPill {
            ForEach(offeredPolicies, id: \.self) { policy in
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
            HStack(spacing: theme.space.s4) {
                Image(systemName: ToolPolicyStyle.icon(for: info.effectivePolicy))
                    .glyphSize(.tiny, weight: .semibold)
                Text(ToolPolicyStyle.compactTitle(for: info.effectivePolicy))
                    .font(SettingsFont.chip)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .glyphSize(.tiny, weight: .bold)
                    .opacity(theme.isDark ? 0.7 : 1)
            }
            .foregroundStyle(color)
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
        .settingsSwitch()
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
        case .ready: theme.status.success.foreground
        case .off: theme.text.secondary
        case .needsAttention: theme.status.warning.foreground
        }
    }

    var body: some View {
        StatusChip(status.displayLabel, tint: tint)
            .help(Text(detail))
            .accessibilityLabel(Text("Status: \(status.displayLabel). \(detail)", bundle: .module))
    }
}

// MARK: - Tool Section Header

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
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.text.link)
                    .frame(width: 16)

                Text(title)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)

                CountBadge(count)

                Spacer()

                Image(systemName: "chevron.right")
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, theme.space.s8)
            .frame(height: 36)
            .settingsChrome(.inset)
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
            HStack(spacing: theme.space.s6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .glyphSize(.micro, weight: .semibold)
                if isExpanded {
                    Text("Show fewer", bundle: .module)
                        .font(SettingsFont.compactLabel)
                } else {
                    Text("Show \(hiddenCount) more", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                Spacer()
            }
            .foregroundColor(theme.text.link)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
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
        MenuPill {
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
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon)
                    .glyphSize(.micro, weight: .semibold)
                Text(selection.title)
                    .font(SettingsFont.smallLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .glyphSize(.tiny, weight: .bold)
                    .foregroundColor(theme.text.tertiary)
            }
            .foregroundColor(theme.text.primary)
        }
        .fixedSize()
        .accessibilityLabel(Text("\(accessibilityTitle): \(selection.title)"))
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s10) {
                ToolRowIcon(systemName: "terminal", showsWarning: hasMissingSystemPermissions)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: theme.space.s8) {
                ToolSourceBadge(title: badge)
                Spacer(minLength: 8)
            }
            .padding(.leading, theme.space.s40)
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            HStack(spacing: theme.space.s4) {
                Text(entry.name)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s10) {
                ToolRowIcon(systemName: "function", showsWarning: hasMissingSystemPermissions)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: theme.space.s8) {
                if let sourceLabel {
                    ToolSourceBadge(title: sourceLabel)
                }
                Spacer(minLength: 8)
                ToolEnableToggle(entry: entry, onChange: onChange)
            }
            .padding(.leading, theme.space.s40)
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            HStack(spacing: theme.space.s4) {
                Text(entry.name)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)

                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s10) {
                ToolRowIcon(systemName: "function", showsWarning: false)
                toolInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                policyMenu
            }

            HStack(spacing: theme.space.s8) {
                ToolSourceBadge(title: providerName)
                Spacer(minLength: 8)
                ToolEnableToggle(entry: entry, onChange: onChange)
            }
            .padding(.leading, theme.space.s40)
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            HStack(spacing: theme.space.s4) {
                Text(displayName)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                ToolCatalogStatusPill(status: status, detail: availability.displayDetail)
            }
            Text(entry.description)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
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
        StatusChip(title, help: L("Where this tool comes from"))
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
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(
                    showsWarning
                        ? theme.status.warning.background : theme.status.info.background
                )
            Image(systemName: systemName)
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(showsWarning ? theme.status.warning.foreground : theme.text.link)

            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(.tiny)
                    .foregroundColor(theme.status.warning.foreground)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 28, height: 28)
    }
}
