//
//  RecentFoldersPanel.swift
//  osaurus
//
//  Recently attached working folders, listed inside the composer's + attach
//  menu directly beneath the Add Folder row. Add Folder itself keeps opening
//  the open panel; these rows are one-click shortcuts to the last few picks.
//

import SwiftUI

/// Rows for the recent-folders list. Each shows the folder name with the
/// full path as a tooltip, a check on the chat's current folder, and a
/// remove affordance on hover. Indented under the Add Folder row it follows.
struct RecentFoldersList: View {
    @ObservedObject private var store = RecentFoldersStore.shared

    /// Path of the folder currently attached to the chat, if any.
    var activePath: String? = nil
    let onPick: (RecentFoldersStore.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            Button(action: onPick) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "checkmark" : "folder")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 12)
                        .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                    Text(verbatim: entry.name)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                // Indented under the Add Folder row: its icon column plus gap.
                .padding(.leading, 12 + 16 + 10)
                .padding(.vertical, 4)
                // Leave room for the remove button so it never overlaps the name.
                .padding(.trailing, 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? theme.secondaryBackground.opacity(0.8) : Color.clear)
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.path)
            .accessibilityLabel(Text(verbatim: entry.name))
            .accessibilityValue(Text(verbatim: entry.path))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            .overlay(alignment: .trailing) {
                if isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(theme.secondaryBackground.opacity(0.9)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .localizedHelp("Remove from recent folders")
                    .accessibilityLabel(Text("Remove from recent folders", bundle: .module))
                }
            }
        }
    }
}
