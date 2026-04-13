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
    @Environment(\.colorScheme) private var colorScheme

    private let rowHeight: CGFloat = 44
    private let maxVisibleRows: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.2)
            commandList
            Divider()
                .opacity(0.2)
            newCommandFooter
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

    // MARK: - New Command Footer

    private var newCommandFooter: some View {
        Button {
            AppDelegate.shared?.showManagementWindow(initialTab: .commands)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("New Command", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "command")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text("Commands", bundle: .module)
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

    // MARK: - Command List

    private var commandList: some View {
        let visibleCount = min(commands.count, maxVisibleRows)
        let listHeight = CGFloat(visibleCount) * rowHeight

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command: command, index: index)
                            .id(index)
                        if index < commands.count - 1 {
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

    // MARK: - Command Row

    private func commandRow(command: SlashCommand, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return Button {
            onSelect(command)
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? theme.accentColor.opacity(0.15)
                                : theme.tertiaryBackground.opacity(0.5)
                        )
                        .frame(width: 26, height: 26)
                    Image(systemName: command.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                }

                // Text
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("/\(command.name)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
                        if command.isBuiltIn {
                            Text("built-in", bundle: .module)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground.opacity(0.6))
                                )
                        }
                    }
                    if !command.description.isEmpty {
                        Text(command.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .background(
                isSelected
                    ? theme.accentColor.opacity(theme.isDark ? 0.12 : 0.08)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                selectedIndex = index
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
