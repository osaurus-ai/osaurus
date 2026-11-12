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
    var title = L("Commands")
    var showsCommandPrefix = true
    var emptyMessage = L("No matching commands")
    var footerTitle = L("New Command")
    var onFooter: (() -> Void)? = nil
    var usesTertiaryEmptyAction = false
    var fitsPresentedHeight = false
    var onIdealHeightChange: ((CGFloat) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.anchoredCardMetrics) private var presentedMetrics

    @State private var hoveredIndex: Int? = nil
    @State private var headingHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    private let maxVisibleRows: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.body.verticalGap", inheriting: SuggestionInspectionStyle.metric("gap", theme.space.s4, theme))) {
            PickerCardHeading(title: title, assignmentFamily: 25) {
                if !commands.isEmpty { PickerCardKeyHints() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headingHeight = $0 }
            if commands.isEmpty {
                Text(verbatim: emptyMessage)
                    .suggestionTextStyle(.label, property: "text")
                    .suggestionInk("secondary", fallback: theme.text.secondary)
                    .padding(.vertical, theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.body.paddingY", inheriting: SuggestionInspectionStyle.metric("padding", theme.space.s14, theme))).catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.body.paddingY")
            } else { commandList }
            Group {
                if commands.isEmpty && usesTertiaryEmptyAction {
                    SettingsButton(.tertiary, footerTitle, size: .extraSmall, verbatim: true, action: performFooter)
                } else {
                    PickerCardTextLink(title: footerTitle, icon: "plus", fillsWidth: false, assignmentFamily: 25,
                        action: performFooter)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }.catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.body.paddingX", inheriting: SuggestionInspectionStyle.metric("padding", PickerCardMetrics.padding, theme))).catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.body.paddingX")
        .padding(.top, theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.body.paddingY2", inheriting: SuggestionInspectionStyle.metric("padding", theme.space.s14, theme))).catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.body.paddingY2")
        .padding(.bottom, theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.body.paddingY3", inheriting: SuggestionInspectionStyle.metric("padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.body.paddingY3")
        .frame(maxWidth: .infinity)
        .pickerCardSurface(elevated: true, assignmentFamily: 25)
        // Size the surface as well as its content before the composer's
        // overlay proposes the (much smaller) input-card height.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // Report the natural height even when the list is constrained,
            // so resizing can expand it again without a feedback loop.
            onIdealHeightChange?(height + max(0, naturalListHeight - listHeight))
        }
    }

    private func performFooter() {
        if let onFooter { onFooter() }
        else { AppDelegate.shared?.showManagementWindow(initialTab: .commands) }
    }

    // MARK: - Command List

    private var naturalListHeight: CGFloat {
        let visibleCount = CGFloat(min(commands.count, maxVisibleRows))
        return visibleCount * SuggestionInspectionStyle.rowHeight(theme)
            + max(0, visibleCount - 1) * SuggestionInspectionStyle.metric("gap", PickerCardMetrics.rowSpacing, theme)
    }

    private var listHeight: CGFloat {
        guard fitsPresentedHeight, let presentedMetrics else { return naturalListHeight }
        let chrome = headingHeight + footerHeight
            + SuggestionInspectionStyle.metric("padding", theme.space.s14, theme)
            + SuggestionInspectionStyle.metric("padding", theme.space.s6, theme)
            + 2 * SuggestionInspectionStyle.metric("gap", theme.space.s4, theme)
        return min(naturalListHeight, max(0, presentedMetrics.visibleSize.height - chrome))
    }

    private var commandList: some View {
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.commandList.verticalGap", inheriting: SuggestionInspectionStyle.metric("gap", PickerCardMetrics.rowSpacing, theme))) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command: command, index: index)
                            .id(index)
                    }
                }.catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.commandList.verticalGap")
            }
            .frame(height: listHeight)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(theme.motion.quick) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Command Row

    private func commandRow(command: SlashCommand, index: Int) -> some View {
        let isHighlighted = index == selectedIndex || index == hoveredIndex

        return Button {
            onSelect(command)
        } label: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.slashCommandPopup.commandRow.horizontalGap", inheriting: SuggestionInspectionStyle.metric("gap", theme.space.s8, theme))) {
                Image(systemName: command.icon)
                    .glyphSize(.caption, weight: .medium)
                    .suggestionInk("accent", fallback: isHighlighted ? theme.text.primary : theme.text.secondary)
                    .frame(width: 16)
                Text(verbatim: showsCommandPrefix ? "/\(command.name)" : command.name)
                    .suggestionTextStyle(.label, property: "label")
                    .suggestionInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !command.description.isEmpty {
                    Text(verbatim: command.description)
                        .suggestionTextStyle(.label, property: "text")
                        .suggestionInk("secondary", fallback: theme.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // Built-ins are the norm; only user commands get a tag.
                if !command.isBuiltIn && command.kind != .workflow {
                    Text("Custom", bundle: .module)
                        .suggestionTextStyle(.footnote, property: "caption")
                        .suggestionInk("secondary", fallback: theme.text.tertiary)
                }
            }.catalogLayoutTarget("component.library.40.elements.layout.slashCommandPopup.commandRow.horizontalGap")
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

/// The same suggestion card and rows as slash commands, backed by the saved
/// workflow library rather than an agent's automatic workflow permissions.
struct WorkflowCommandPicker: View {
    let onSelect: (UUID) -> Void
    let onOpenWorkflows: () -> Void
    @ObservedObject private var workflows = InstalledWorkflowStore.shared
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var commands: [SlashCommand] {
        workflows.workflows.map { workflow in
            SlashCommand(id: workflow.id, name: workflow.name,
                description: workflow.summary ?? "", icon: "flowchart", kind: .workflow)
        }
    }

    var body: some View {
        SlashCommandPopup(commands: commands, selectedIndex: $selectedIndex,
            onSelect: { onSelect($0.id) }, title: L("Workflows"),
            showsCommandPrefix: false, emptyMessage: L("No workflows available"),
            footerTitle: commands.isEmpty ? L("Create your first workflow") : L("Open Workflows"),
            onFooter: onOpenWorkflows, usesTertiaryEmptyAction: true)
            .focusable().focusEffectDisabled().focused($focused)
            .onAppear {
                workflows.reload()
                selectedIndex = 0
                focused = true
            }
            .onChange(of: commands.map(\.id)) { _, _ in
                selectedIndex = min(selectedIndex, max(0, commands.count - 1))
            }
            .onMoveCommand { direction in
                guard !commands.isEmpty else { return }
                if direction == .down { selectedIndex = (selectedIndex + 1) % commands.count }
                else if direction == .up { selectedIndex = (selectedIndex - 1 + commands.count) % commands.count }
            }
            .onKeyPress(.return) {
                guard commands.indices.contains(selectedIndex) else { return .ignored }
                onSelect(commands[selectedIndex].id)
                return .handled
            }
    }
}
