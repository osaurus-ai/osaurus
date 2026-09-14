//
//  RecentFoldersPanel.swift
//  osaurus
//
//  Recently attached working folders, shown as chips at the bottom of the
//  composer's + attach menu. Add Folder keeps opening the open panel; the
//  chips are one-click shortcuts to the last few picks.
//

import SwiftUI

/// Wrapping row of recent-folder chips. Each shows the folder name with the
/// full path as a tooltip, highlights the chat's current folder, and grows a
/// remove affordance on hover.
struct RecentFoldersList: View {
    @ObservedObject private var store = RecentFoldersStore.shared
    @Environment(\.theme) private var theme

    /// Path of the folder currently attached to the chat, if any.
    var activePath: String? = nil
    let onPick: (RecentFoldersStore.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Folders", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
            FlowLayout(spacing: 6) {
                ForEach(store.entries) { entry in
                    RecentFolderChip(
                        entry: entry,
                        isActive: entry.path == activePath,
                        onPick: { onPick(entry) },
                        onRemove: { store.remove(path: entry.path) }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear { store.pruneMissing() }
    }

    private struct RecentFolderChip: View {
        let entry: RecentFoldersStore.Entry
        let isActive: Bool
        let onPick: () -> Void
        let onRemove: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 4) {
                Button(action: onPick) {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "folder.fill" : "folder")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                        Text(verbatim: entry.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 140)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: entry.name))
                .accessibilityValue(Text(verbatim: entry.path))

                // Remove affordance appears on hover so chips stay compact.
                if isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 12, height: 12)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .localizedHelp("Remove from recent folders")
                    .accessibilityLabel(Text("Remove from recent folders", bundle: .module))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isActive
                            ? theme.accentColor.opacity(0.12)
                            : theme.secondaryBackground.opacity(isHovering ? 0.9 : 0.6)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? theme.accentColor.opacity(0.35) : theme.primaryBorder.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .help(entry.path)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }
}

// MARK: - List variant

/// Recent folders as plain rows (folder name, dimmed path, remove on hover)
/// for settings surfaces such as the agent editor's Working Folder row,
/// where a vertical list reads better than chips.
struct RecentFoldersRows: View {
    @ObservedObject private var store = RecentFoldersStore.shared
    @Environment(\.theme) private var theme

    /// Path currently applied by the host surface, shown with a check.
    var activePath: String? = nil
    let onPick: (RecentFoldersStore.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Folders", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            ForEach(store.entries) { entry in
                RecentFolderRow(
                    entry: entry,
                    isActive: entry.path == activePath,
                    onPick: { onPick(entry) },
                    onRemove: { store.remove(path: entry.path) }
                )
            }
        }
        .onAppear { store.pruneMissing() }
    }

    private struct RecentFolderRow: View {
        let entry: RecentFoldersStore.Entry
        let isActive: Bool
        let onPick: () -> Void
        let onRemove: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 8) {
                Button(action: onPick) {
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "checkmark" : "folder")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 12)
                            .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                        Text(verbatim: entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        Text(verbatim: entry.path)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.path)
                .accessibilityLabel(Text(verbatim: entry.name))
                .accessibilityValue(Text(verbatim: entry.path))

                if isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .localizedHelp("Remove from recent folders")
                    .accessibilityLabel(Text("Remove from recent folders", bundle: .module))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.secondaryBackground.opacity(0.7) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }
}
