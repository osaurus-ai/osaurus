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
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text("Recent Folders", bundle: .module)
                .textStyle(.micro, weight: 600)
                .foregroundColor(theme.text.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, theme.space.s2)
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
                HStack(spacing: theme.space.s8) {
                    Image(systemName: isActive ? "checkmark" : "folder")
                        .glyphSize(.footnote, weight: .medium)
                        .frame(width: 16)
                        .foregroundColor(isActive ? theme.text.primary : theme.text.secondary)
                    Text(verbatim: entry.name)
                        .textStyle(.caption, weight: 500)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsPath {
                        Text(verbatim: entry.path)
                            .textStyle(.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, horizontalInset)
                // Constant trailing room for the overlaid remove button, so
                // its appearance on hover never re-truncates or reflows.
                .padding(.trailing, horizontalInset + 20)
                .padding(.vertical, theme.space.s6)
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(isHovering ? theme.surface.subtle : Color.clear)
                )
                .padding(.horizontal, theme.space.s6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.path)
            .accessibilityLabel(Text(verbatim: entry.name))
            .accessibilityValue(Text(verbatim: entry.path))
            .onHover { hovering in
                withAnimation(theme.motion.quick) { isHovering = hovering }
            }
            .overlay(alignment: .trailing) {
                SettingsIconButton("xmark", help: "Remove from recent folders", size: .extraExtraSmall, action: onRemove)
                    .padding(.trailing, horizontalInset + 2)
                // Always laid out, only shown on hover: an `if` here would
                // insert and remove the view, which is the reflow we avoid.
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
        }
    }
}
