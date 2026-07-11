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
    @Binding var selectedIndex: Int
    let onSelect: (AtFileItem) -> Void

    @Environment(\.theme) private var theme

    @State private var hoveredIndex: Int? = nil

    private let rowHeight: CGFloat = 40
    private let maxVisibleRows: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.2)
            fileList
        }
        .frame(maxWidth: .infinity)
        .background(popupBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: theme.shadowColor.opacity(0.18), radius: 16, x: 0, y: 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "at")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text("Files", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Spacer()
            Text("↑↓ navigate  ↵ select  esc dismiss", bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - File List

    private var fileList: some View {
        let visibleCount = min(items.count, maxVisibleRows)
        let listHeight = CGFloat(visibleCount) * rowHeight

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        fileRow(item: item, index: index)
                            .id(index)
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 40)
                                .opacity(0.1)
                        }
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
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex
        let isHighlighted = isSelected || isHovered

        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isHighlighted
                                ? theme.accentColor.opacity(0.15)
                                : theme.tertiaryBackground.opacity(0.5)
                        )
                        .frame(width: 24, height: 24)
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHighlighted ? theme.accentColor : theme.secondaryText)
                }

                Text(item.isDirectory ? "\(item.name)/" : item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHighlighted ? theme.accentColor : theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .background(
                isHighlighted
                    ? theme.accentColor.opacity(theme.isDark ? 0.12 : 0.08)
                    : Color.clear
            )
            .contentShape(Rectangle())
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

    // MARK: - Background

    private var popupBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.92 : 0.97))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.4)
        }
    }
}
