//
//  AgentCreatorIntro.swift
//  osaurus
//
//  What a New Agent chat shows before anything is drafted: one question,
//  a few starting points, and a way to fill the agent in by hand. The
//  agent card stays hidden until there is something to put on it.
//

import SwiftUI

/// The three stages of making an agent, shown above the intro and the card.
enum AgentCreationStage: Int, CaseIterable, Comparable, Identifiable {
    case describe, shape, create

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .describe: return L("Describe")
        case .shape: return L("Shape")
        case .create: return L("Create")
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AgentCreationStepper: View {
    @Environment(\.theme) private var theme
    let stage: AgentCreationStage

    var body: some View {
        HStack(spacing: theme.space.s6) {
            ForEach(AgentCreationStage.allCases) { item in
                if item != .describe {
                    Rectangle()
                        .fill(item <= stage ? theme.statusInk(.success) : theme.border.default)
                        .frame(width: theme.space.s16, height: theme.stroke.default)
                }
                HStack(spacing: theme.space.s4) {
                    marker(item)
                    Text(verbatim: item.title)
                        .textStyle(.caption, weight: item == stage ? 600 : 400)
                        .foregroundStyle(item == stage ? theme.text.primary : theme.text.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .animation(theme.motion.standard, value: stage)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress", bundle: .module))
        .accessibilityValue(
            Text(verbatim: L("Step \(stage.rawValue + 1) of \(AgentCreationStage.allCases.count): \(stage.title)")))
    }

    @ViewBuilder
    private func marker(_ item: AgentCreationStage) -> some View {
        if item < stage {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(theme.statusInk(.success))
        } else if item == stage {
            Image(systemName: "circle.inset.filled")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(theme.statusInk(.info))
        } else {
            Image(systemName: "circle")
                .glyphSize(.micro)
                .foregroundStyle(theme.text.tertiary)
        }
    }
}

struct AgentCreatorIntro: View {
    /// A model can answer, so the Configurator can draft.
    let canDraft: Bool
    /// Sends a starting point to the Configurator.
    let onStarter: (AgentStarterTemplate) -> Void
    /// Shows the agent card to fill in by hand.
    let onFillIn: () -> Void
    let onChooseModel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: theme.space.s32) {
                    hero
                    if canDraft { starters } else { noModelNotice }
                    WorkflowTextLink(title: L("Fill it in yourself instead"), icon: "square.and.pencil", action: onFillIn)
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
            SettingsIconTile(icon: "person.crop.circle.badge.plus", size: theme.space.s40, tint: theme.status.info.foreground)
                .accessibilityHidden(true)
            Text("What should your new agent do?", bundle: .module)
                .assignedTypography("type.subheading", fallback: SettingsFont.rowTitle)
                .foregroundStyle(theme.text.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(
                canDraft
                    ? L(
                        "Describe it below in your own words. The Configurator asks only what it needs and builds the agent beside the chat. Nothing is saved until you click Create Agent."
                    )
                    : L("Fill in a name and a few details, and click Create Agent. Nothing is saved until then.")
            )
            .textStyle(.body)
            .foregroundStyle(theme.text.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            AgentCreationStepper(stage: .describe)
                .padding(.top, theme.space.s8)
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            WorkflowSectionHeader(title: L("Or start from an idea"))
            VStack(spacing: theme.space.s0) {
                let templates = AgentStarterTemplate.allCases.filter { $0 != .blank }
                ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                    if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                    AgentStarterRow(template: template) { onStarter(template) }
                }
            }
            .settingsChrome(.card)
        }
    }

    private var noModelNotice: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Image(systemName: "cpu")
                .glyphSize(.body, weight: .medium)
                .foregroundStyle(theme.status.warning.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("No model is set up yet, so the Configurator can't draft with you.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundStyle(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsButton(.secondary, L("Choose a Model"), icon: "cpu", size: .small, verbatim: true, action: onChooseModel)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space.s16)
        .settingsChrome(.status(.warning))
    }
}

/// One starting point: its icon, name and one-line job. Picking it sends it.
private struct AgentStarterRow: View {
    let template: AgentStarterTemplate
    let onPick: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: theme.space.s12) {
                SettingsIconTile(icon: template.icon)
                    .accessibilityHidden(true)
                SettingsRowText {
                    Text(verbatim: template.label)
                } description: {
                    Text(verbatim: template.tagline)
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .glyphSize(.micro, weight: .semibold)
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
        .accessibilityHint(Text("Starts the agent from this idea.", bundle: .module))
    }
}
