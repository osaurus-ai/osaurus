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
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.body.verticalGap", inheriting: SuggestionInspectionStyle.metric("gap", 4, theme))) {
            PickerCardHeading(title: L("Files"), assignmentFamily: 25) {
                PickerCardKeyHints()
            }
            if status == .denied {
                deniedRow
            } else if items.isEmpty {
                emptyRow
            } else {
                fileList
            }
        }.catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.body.paddingX", inheriting: SuggestionInspectionStyle.metric("padding", PickerCardMetrics.padding, theme))).catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.body.paddingX")
        .padding(.top, theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.body.paddingY", inheriting: SuggestionInspectionStyle.metric("padding", 14, theme))).catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.body.paddingY")
        .padding(.bottom, theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.body.paddingY2", inheriting: SuggestionInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.body.paddingY2")
        .frame(maxWidth: .infinity)
        .pickerCardSurface(elevated: true, assignmentFamily: 25)
        #if OSAURUS_DESIGN_SYSTEM
        // Size the surface as well as its content before the composer's
        // overlay proposes the (much smaller) input-card height.
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    // MARK: - Denied Access Row

    /// Shown when macOS blocked the folder. Tapping re-requests access via an
    /// open panel — the only in-app way to recover, since the OS won't re-prompt
    /// on its own after a denial.
    private var deniedRow: some View {
        Button(action: onGrantAccess) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.deniedRow.horizontalGap", inheriting: SuggestionInspectionStyle.metric("gap", 8, theme))) {
                Image(systemName: "lock.fill")
                    .glyphSize(12, weight: .medium)
                    .suggestionInk("error", fallback: theme.status.warning.foreground)
                    .frame(width: 16)
                Text("Can't access \(deniedDirectoryName)", bundle: .module)
                    .suggestionTextStyle(.label, property: "label")
                    .suggestionInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("Click to grant access\u{2026}", bundle: .module)
                    // Slanting arrow signals the row opens an external picker.
                    Image(systemName: "arrow.up.right")
                        .glyphSize(10, weight: .semibold)
                }
                .suggestionTextStyle(.label, property: "caption")
                .suggestionInk("accent", fallback: theme.text.link)
            }.catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.deniedRow.horizontalGap")
            .suggestionRowChrome(hovered: deniedRowHovered)
        }
        .assignedBasePlainButtonStyle()
        .onHover { deniedRowHovered = $0 }
    }

    // MARK: - Empty State

    /// Non-interactive row shown when the directory read fine but has nothing to
    /// list, so the menu reads as "nothing here" rather than looking broken.
    private var emptyRow: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.emptyRow.horizontalGap", inheriting: SuggestionInspectionStyle.metric("gap", 8, theme))) {
            Image(systemName: "folder")
                .glyphSize(12, weight: .medium)
                .suggestionInk("secondary", fallback: theme.text.tertiary)
                .frame(width: 16)
            Text(emptyMessage)
                .suggestionTextStyle(.bodySmall, property: "text")
                .suggestionInk("secondary", fallback: theme.text.secondary)
            Spacer(minLength: 0)
        }.catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.emptyRow.horizontalGap")
        .suggestionRowChrome()
    }

    // MARK: - File List

    private var fileList: some View {
        let visibleCount = CGFloat(min(items.count, maxVisibleRows))
        let listHeight =
            visibleCount * SuggestionInspectionStyle.rowHeight(theme) + max(0, visibleCount - 1) * SuggestionInspectionStyle.metric("gap", PickerCardMetrics.rowSpacing, theme)

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.fileList.verticalGap", inheriting: SuggestionInspectionStyle.metric("gap", PickerCardMetrics.rowSpacing, theme))) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        fileRow(item: item, index: index)
                            .id(index)
                    }
                }.catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.fileList.verticalGap")
            }
            .frame(height: listHeight)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(theme.motion.quick) {
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
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.atFileMenuPopup.fileRow.horizontalGap", inheriting: SuggestionInspectionStyle.metric("gap", 8, theme))) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .glyphSize(12, weight: .medium)
                    .suggestionInk("accent", fallback: isHighlighted ? theme.text.primary : theme.text.secondary)
                    .frame(width: 16)
                Text(verbatim: item.isDirectory ? "\(item.name)/" : item.name)
                    .suggestionTextStyle(.label, property: "label")
                    .suggestionInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }.catalogLayoutTarget("component.library.40.elements.layout.atFileMenuPopup.fileRow.horizontalGap")
            .suggestionRowChrome(selected: index == selectedIndex, hovered: index == hoveredIndex)
        }
        .assignedBasePlainButtonStyle()
        .onHover { hovering in
            if hovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
    }
}
