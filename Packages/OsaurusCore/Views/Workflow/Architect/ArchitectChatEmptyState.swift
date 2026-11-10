//
//  ArchitectChatEmptyState.swift
//  osaurus
//
//  What an Architect chat shows before its first message. A new workflow
//  gets a guided start (the draft pane stays hidden until there is
//  something in it); a draft that already has steps, such as a saved
//  workflow opened for changes, gets ways to begin changing it.
//

import SwiftUI

struct ArchitectChatEmptyState: View {
    enum Mode: Equatable {
        /// Nothing drafted yet.
        case start
        /// A draft with steps and no conversation.
        case edit(workflowName: String, stepCount: Int, isSaved: Bool)
    }

    let mode: Mode
    let quickActions: [AgentQuickAction]
    /// Puts a suggestion's text in the composer.
    let onPick: (String) -> Void
    /// Opens Workflows, to pick a saved workflow to change instead.
    var onBrowse: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: theme.space.s32) {
                    hero
                    suggestions
                    if mode == .start, let onBrowse {
                        WorkflowTextLink(title: L("Change a saved workflow instead"), icon: "arrow.uturn.right") {
                            onBrowse()
                        }
                    }
                }
                .frame(maxWidth: WorkflowLibraryLayout.columnWidth)
                .padding(.horizontal, theme.space.s24)
                .padding(.vertical, theme.space.s32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var hero: some View {
        VStack(spacing: theme.space.s12) {
            SettingsIconTile(icon: icon, size: theme.space.s40, tint: theme.status.info.foreground)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .assignedTypography("type.subheading", fallback: SettingsFont.rowTitle)
                .foregroundStyle(theme.text.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle)
                .textStyle(.body)
                .foregroundStyle(theme.text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .start {
                WorkflowStageStepper(stage: .design)
                    .padding(.top, theme.space.s8)
            }
        }
    }

    private var icon: String {
        switch mode {
        case .start: return "wand.and.stars"
        case .edit: return "pencil.and.list.clipboard"
        }
    }

    private var title: String {
        switch mode {
        case .start: return L("What should this workflow do?")
        case .edit(let name, _, _): return L("What should change in \(name)?")
        }
    }

    private var subtitle: String {
        switch mode {
        case .start:
            return L(
                "Describe the task in your own words below. The Architect asks only what it needs, builds the steps, and tests them with you before anything is saved."
            )
        case .edit(_, let steps, let isSaved):
            let stepLine = steps == 1 ? L("Its step is on the right.") : L("Its \(steps) steps are on the right.")
            let saveLine = isSaved
                ? L("Saving makes the next version; the one you run now stays until then.")
                : L("Nothing is saved until you test it and choose Save.")
            return "\(stepLine) \(L("Tell the Architect what to change, or start from one of these.")) \(saveLine)"
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if !quickActions.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                WorkflowSectionHeader(title: mode == .start ? L("Or start from an idea") : L("Start from"))
                VStack(spacing: 0) {
                    ForEach(Array(quickActions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                        ArchitectSuggestionRow(action: action) { onPick(action.prompt) }
                    }
                }
                .settingsChrome(.card)
            }
        }
    }
}

/// One suggestion: its icon, its words, and an arrow. Picking it puts the
/// prompt in the composer to finish, never sends it.
private struct ArchitectSuggestionRow: View {
    let action: AgentQuickAction
    let onPick: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: theme.space.s12) {
                Image(systemName: action.icon)
                    .glyphSize(12)
                    .foregroundStyle(theme.status.info.foreground)
                    .frame(width: theme.space.s16)
                    .accessibilityHidden(true)
                Text(verbatim: action.text)
                    .textStyle(.body)
                    .foregroundStyle(theme.text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.left")
                    .glyphSize(10, weight: .semibold)
                    .foregroundStyle(isHovered ? theme.text.secondary : theme.text.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s12)
            .contentShape(Rectangle())
            .settingsChrome(isHovered ? .hover : nil, radius: theme.radius.medium)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(theme.motion.quick, value: isHovered)
        .pointingHandCursor()
        .accessibilityHint(Text("Puts this in the message box to finish and send.", bundle: .module))
    }
}
