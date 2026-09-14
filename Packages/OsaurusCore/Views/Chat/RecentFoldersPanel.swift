//
//  RecentFoldersPanel.swift
//  osaurus
//
//  Recently attached working folders as a vertical list. Used at the bottom
//  of the composer's + attach menu (Add Folder keeps opening the open panel;
//  these rows are one-click shortcuts) and under the agent editor's Working
//  Folder row.
//

import SwiftUI

/// Vertical list of recent folders under a small "Recent Folders" label.
/// Each row shows the folder name (optionally the dimmed path beside it),
/// a check on the active folder, and a remove affordance on hover. The
/// remove button lives in an overlay so hovering never changes layout.
struct RecentFoldersList: View {
    @ObservedObject private var store = RecentFoldersStore.shared
    @Environment(\.theme) private var theme

    /// Path currently applied by the host surface, shown with a check.
    var activePath: String? = nil
    /// Show the full path dimmed beside the name. Off in the narrow + menu
    /// (the tooltip carries it), on in the roomier agent editor.
    var showsPath: Bool = false
    /// Horizontal inset so the label lines up with the host's own rows.
    var horizontalInset: CGFloat = 12
    let onPick: (RecentFoldersStore.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Folders", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, 2)
            ForEach(store.entries) { entry in
                RecentFolderRow(
                    entry: entry,
                    isActive: entry.path == activePath,
                    showsPath: showsPath,
                    horizontalInset: horizontalInset,
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
        let showsPath: Bool
        let horizontalInset: CGFloat
        let onPick: () -> Void
        let onRemove: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: onPick) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "checkmark" : "folder")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16)
                        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                    Text(verbatim: entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsPath {
                        Text(verbatim: entry.path)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, horizontalInset)
                // Constant trailing room for the overlaid remove button, so
                // its appearance on hover never re-truncates or reflows.
                .padding(.trailing, horizontalInset + 20)
                .padding(.vertical, 6)
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
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(theme.secondaryBackground.opacity(0.9)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, horizontalInset + 2)
                .localizedHelp("Remove from recent folders")
                .accessibilityLabel(Text("Remove from recent folders", bundle: .module))
                // Always laid out, only shown on hover: an `if` here would
                // insert and remove the view, which is the reflow we avoid.
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
        }
    }
}
