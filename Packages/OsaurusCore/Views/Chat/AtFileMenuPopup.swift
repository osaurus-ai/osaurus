//
//  AtFileMenuPopup.swift
//  osaurus
//
//  Floating popup shown above the chat input when the user types @
//  Displays a filtered, keyboard-navigable list of filesystem entries so the
//  user can complete a file or folder path CLI-style. Mirrors the visual
//  language of SlashCommandPopup.
//

import SwiftUI

struct AtFileMenuPopup: View {
    let items: [AtFileItem]
    /// Outcome of the current listing; drives the denied-access affordance.
    let status: AtFileMenuStatus
    /// Leaf name of the blocked directory, shown in the denied row.
    let deniedDirectoryName: String
    /// Message for the empty state (e.g. "This folder is empty" vs "No matching
    /// files"), decided by the caller which knows whether a filter is active.
    let emptyMessage: String
    @Binding var selectedIndex: Int
    let onSelect: (AtFileItem) -> Void
    /// Invoked from the denied row to re-request access to the folder.
    let onGrantAccess: () -> Void

    @Environment(\.theme) private var theme

    @State private var hoveredIndex: Int? = nil
    @State private var deniedRowHovered = false

    private let maxVisibleRows: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PickerCardHeading(title: L("Files")) {
                PickerCardKeyHints()
            }
            if status == .denied {
                deniedRow
            } else if items.isEmpty {
                emptyRow
            } else {
                fileList
            }
        }
        .padding(.horizontal, PickerCardMetrics.padding)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .pickerCardSurface(elevated: true)
    }

    // MARK: - Denied Access Row

    /// Shown when macOS blocked the folder. Tapping re-requests access via an
    /// open panel — the only in-app way to recover, since the OS won't re-prompt
    /// on its own after a denial.
    private var deniedRow: some View {
        Button(action: onGrantAccess) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.warningColor)
                    .frame(width: 16)
                Text("Can't access \(deniedDirectoryName)", bundle: .module)
                    .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("Click to grant access\u{2026}", bundle: .module)
                    // Slanting arrow signals the row opens an external picker.
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                .foregroundStyle(theme.accentColor)
            }
            .pickerCardRowChrome(highlighted: deniedRowHovered)
        }
        .buttonStyle(.plain)
        .onHover { deniedRowHovered = $0 }
    }

    // MARK: - Empty State

    /// Non-interactive row shown when the directory read fine but has nothing to
    /// list, so the menu reads as "nothing here" rather than looking broken.
    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .frame(width: 16)
            Text(emptyMessage)
                .font(theme.font(size: theme.pickerCardBodySize))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .pickerCardRowChrome(highlighted: false)
    }

    // MARK: - File List

    private var fileList: some View {
        let visibleCount = CGFloat(min(items.count, maxVisibleRows))
        let listHeight =
            visibleCount * PickerCardMetrics.rowHeight + max(0, visibleCount - 1) * PickerCardMetrics.rowSpacing

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        fileRow(item: item, index: index)
                            .id(index)
                    }
                }
            }
            .frame(height: listHeight)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - File Row

    private func fileRow(item: AtFileItem, index: Int) -> some View {
        let isHighlighted = index == selectedIndex || index == hoveredIndex

        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHighlighted ? theme.primaryText : theme.secondaryText)
                    .frame(width: 16)
                Text(verbatim: item.isDirectory ? "\(item.name)/" : item.name)
                    .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .pickerCardRowChrome(highlighted: isHighlighted)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
    }
}
