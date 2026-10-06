//
//  SlashCommandPopup.swift
//  osaurus
//
//  Floating popup shown above the chat input when the user types /
//  Displays a filtered list of slash commands with keyboard navigation.
//

import SwiftUI

struct SlashCommandPopup: View {
    let commands: [SlashCommand]
    @Binding var selectedIndex: Int
    let onSelect: (SlashCommand) -> Void

    @Environment(\.theme) private var theme

    @State private var hoveredIndex: Int? = nil

    private let maxVisibleRows: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PickerCardHeading(title: L("Commands")) {
                PickerCardKeyHints()
            }
            commandList
            PickerCardTextLink(title: L("New Command"), icon: "plus", fillsWidth: false) {
                AppDelegate.shared?.showManagementWindow(initialTab: .commands)
            }
        }
        .padding(.horizontal, PickerCardMetrics.padding)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .pickerCardSurface(elevated: true)
    }

    // MARK: - Command List

    private var commandList: some View {
        let visibleCount = CGFloat(min(commands.count, maxVisibleRows))
        let listHeight =
            visibleCount * PickerCardMetrics.rowHeight + max(0, visibleCount - 1) * PickerCardMetrics.rowSpacing

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command: command, index: index)
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

    // MARK: - Command Row

    private func commandRow(command: SlashCommand, index: Int) -> some View {
        let isHighlighted = index == selectedIndex || index == hoveredIndex
        let bodyFont = theme.font(size: theme.pickerCardBodySize)

        return Button {
            onSelect(command)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: command.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHighlighted ? theme.primaryText : theme.secondaryText)
                    .frame(width: 16)
                Text(verbatim: "/\(command.name)")
                    .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !command.description.isEmpty {
                    Text(verbatim: command.description)
                        .font(bodyFont)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // Built-ins are the norm; only user commands get a tag.
                if !command.isBuiltIn {
                    Text("Custom", bundle: .module)
                        .font(theme.font(size: theme.pickerCardCaptionSize))
                        .foregroundStyle(theme.tertiaryText)
                }
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
