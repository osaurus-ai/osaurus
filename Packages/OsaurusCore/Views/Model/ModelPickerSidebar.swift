//
//  ModelPickerSidebar.swift
//  osaurus
//
//  Left pane of the model picker: Favorites, On this Mac, Osaurus Cloud,
//  one row per configured provider (with a live status dot), Claude Code,
//  and the "+ Add provider" footer. Collapses to an icon rail when the
//  host window is narrow.
//

import SwiftUI

struct ModelPickerSidebar: View {
    let groups: [ModelPickerGroup]
    /// The group currently shown in the right pane.
    let activeKey: String?
    /// The group that contains the selected model, marked with a small
    /// accent dot so the user can find "where am I" at a glance.
    let selectedModelGroupKey: String?
    /// Icon-rail mode for narrow host windows.
    let isCompact: Bool
    /// True while the right pane shows the inline add-provider catalog.
    let isAddingProvider: Bool
    let onSelect: (String) -> Void
    let onAddProvider: () -> Void

    @Environment(\.theme) private var theme

    static let expandedWidth: CGFloat = 184
    static let compactWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        SidebarRow(
                            group: group,
                            isActive: !isAddingProvider && group.key == activeKey,
                            holdsSelection: group.key == selectedModelGroupKey,
                            isCompact: isCompact,
                            action: { onSelect(group.key) }
                        )
                    }
                }
                .padding(.horizontal, isCompact ? 5 : 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

            Divider().background(theme.primaryBorder.opacity(0.25))

            addProviderButton
                .padding(.horizontal, isCompact ? 5 : 8)
                .padding(.vertical, 8)
        }
        .frame(width: isCompact ? Self.compactWidth : Self.expandedWidth)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.35 : 0.5))
    }

    private var addProviderButton: some View {
        Button(action: onAddProvider) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18)
                if !isCompact {
                    Text("Add provider", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(isAddingProvider ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, isCompact ? 0 : 8)
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isAddingProvider ? theme.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(Text("Add provider", bundle: .module))
        .accessibilityLabel(Text("Add provider", bundle: .module))
    }

    // MARK: - Row

    private struct SidebarRow: View {
        let group: ModelPickerGroup
        let isActive: Bool
        let holdsSelection: Bool
        let isCompact: Bool
        let action: () -> Void

        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 7) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: group.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(iconColor)
                            .frame(width: 18, height: 18)
                        // In the rail the status dot rides the icon corner.
                        if isCompact, let dot = statusDotColor {
                            Circle()
                                .fill(dot)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(theme.primaryBackground, lineWidth: 1))
                                .offset(x: 2, y: 2)
                        }
                    }

                    if !isCompact {
                        Text(group.title)
                            .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                            .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        trailing
                    }
                }
                .padding(.horizontal, isCompact ? 0 : 8)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isActive
                                ? theme.accentColor.opacity(theme.isDark ? 0.16 : 0.12)
                                : (isHovering ? theme.tertiaryBackground.opacity(0.7) : Color.clear)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            .help(helpText)
            .accessibilityLabel(Text(group.title))
            .accessibilityValue(Text(accessibilityValue))
            .accessibilityAddTraits(isActive ? .isSelected : [])
        }

        private var iconColor: Color {
            if group.isFavorites { return isActive ? Color.yellow : Color.yellow.opacity(0.85) }
            return isActive ? theme.accentColor : theme.secondaryText
        }

        /// Trailing affordance: model count for connected/local groups; a
        /// status dot for providers that aren't connected; a small accent dot
        /// marking the group that holds the selected model.
        @ViewBuilder
        private var trailing: some View {
            HStack(spacing: 5) {
                if holdsSelection && !isActive {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 5, height: 5)
                        .help(Text("Contains the selected model", bundle: .module))
                }
                if let dot = statusDotColor, !group.status.isConnected {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                } else {
                    Text("\(group.models.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isActive ? theme.accentColor.opacity(0.9) : theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                isActive ? theme.accentColor.opacity(0.12) : theme.secondaryBackground
                            )
                        )
                }
            }
        }

        private var statusDotColor: Color? {
            switch group.status {
            case .none: return nil
            case .connected: return .green
            case .connecting: return .yellow
            case .disconnected: return .red.opacity(0.85)
            case .needsSignIn: return .orange
            }
        }

        private var helpText: Text {
            switch group.status {
            case .none, .connected:
                return Text("\(group.title) · \(group.models.count)")
            case .connecting:
                return Text("\(group.title) · ") + Text("Connecting…", bundle: .module)
            case .disconnected(let message):
                if let message, !message.isEmpty {
                    return Text("\(group.title) · \(message)")
                }
                return Text("\(group.title) · ") + Text("Not connected", bundle: .module)
            case .needsSignIn:
                return Text("\(group.title) · ") + Text("Sign in required", bundle: .module)
            }
        }

        private var accessibilityValue: String {
            switch group.status {
            case .none, .connected: return "\(group.models.count)"
            case .connecting: return L("Connecting")
            case .disconnected: return L("Not connected")
            case .needsSignIn: return L("Sign in required")
            }
        }
    }
}
