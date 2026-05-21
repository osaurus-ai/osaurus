//
//  OnboardingCreateAgentView.swift
//  osaurus
//
//  Onboarding step 2 — a stripped-down "Create your agent" form.
//  Split into:
//    - `CreateAgentState`: ObservableObject holding form state (lives in
//      OnboardingView via @StateObject, so values survive slide transitions).
//    - `CreateAgentBody`: the body slot (template strip + name + mascot).
//    - `CreateAgentCTA`: the primary "Create Agent" footer button.
//    - `CreateAgentSecondary`: the leading "Skip for now" text link.
//

import SwiftUI

// MARK: - State

@MainActor
final class CreateAgentState: ObservableObject {
    @Published var selectedTemplate: AgentStarterTemplate = .writer
    @Published var name: String = ""
    @Published var systemPrompt: String = ""
    /// Flips to `true` once the user types into the name field, so switching
    /// presets stops clobbering their input.
    @Published var nameUserEdited: Bool = false
    /// Flips to `true` once the user edits the system prompt, so switching
    /// presets stops clobbering their changes.
    @Published var systemPromptUserEdited: Bool = false
    @Published var selectedAvatar: String? = AgentMascot.allCases.first?.id
    @Published var isSaving: Bool = false

    /// ID of the agent created by `saveAgent`. Read by
    /// `OnboardingView.finishOnboarding` to flip
    /// `AgentManager.activeAgentId` so the user lands in chat with the
    /// agent they just made already selected. `nil` when the user
    /// skipped this step.
    @Published private(set) var createdAgentId: UUID?

    init() {
        applyTemplate(.writer)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool { !trimmedName.isEmpty && !isSaving }

    /// Apply a template to the form. The name and system prompt are
    /// overwritten only if the user hasn't edited those fields directly —
    /// once they have, the starter chips become an indicator of "where I
    /// began" rather than a destructive action.
    func applyTemplate(_ template: AgentStarterTemplate) {
        selectedTemplate = template
        if !nameUserEdited {
            name = template.defaultName
        }
        if !systemPromptUserEdited {
            systemPrompt = template.systemPrompt
        }
    }

    /// Persists the agent and returns whether save succeeded. The caller is
    /// responsible for advancing the flow afterwards.
    ///
    /// Idempotent: if the user navigates back from a later onboarding
    /// step and re-fires the CTA, the previously-created agent's id is
    /// returned as success without spawning a duplicate `AgentManager`
    /// entry.
    @discardableResult
    func saveAgent() -> Bool {
        if createdAgentId != nil { return true }
        guard !trimmedName.isEmpty, !isSaving else { return false }
        isSaving = true
        let agent = Agent(
            id: UUID(),
            name: trimmedName,
            description: "",
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            updatedAt: Date(),
            toolSelectionMode: .auto,
            avatar: selectedAvatar
        )
        AgentManager.shared.add(agent)
        createdAgentId = agent.id
        isSaving = false
        return true
    }
}

// MARK: - Body

struct CreateAgentBody: View {
    @ObservedObject var state: CreateAgentState

    @Environment(\.theme) private var theme

    private let formMaxWidth: CGFloat = 440

    var body: some View {
        OnboardingTwoColumnBody(
            leftColumn: { leftColumnContent },
            rightContent: { rightColumnContent }
        )
    }

    // MARK: - Left column

    /// Left-column content for the shared two-column body. The shared
    /// container handles widths, padding, and vertical centring so this
    /// view only needs to lay out the in-column composition.
    private var leftColumnContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            agentPreviewCard

            Spacer().frame(height: OnboardingMetrics.illustrationToHeadline)

            Text("Meet your assistant", bundle: .module)
                .font(theme.font(size: OnboardingMetrics.leftHeadlineSize, weight: .bold))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: OnboardingMetrics.leftHeadlineToBody)

            Text(
                "Pick a starter, then make it yours. The preview updates as you choose an avatar, name, and role.",
                bundle: .module
            )
            .font(theme.font(size: OnboardingMetrics.leftBodySize))
            .foregroundColor(theme.secondaryText)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Right column

    /// Right-column form. Wrapped by the shared two-column body in an
    /// `OnboardingScrollContainer`, so the column gets the standard
    /// scroll buffer (which clears glass-card hover shadows on the
    /// chrome's clip) without each step re-applying it manually.
    private var rightColumnContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sequenced top-to-bottom in dependency order: pick a visual
            // identity (avatar), then a behavior preset (starter) — which
            // prefills both name and prompt — then refine.
            avatarRow
            starterRow
            nameField
            systemPromptField
        }
        .frame(maxWidth: formMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live agent preview rendered as an `OnboardingGlassCard` so the
    /// preview shares the same radius / border / shadow vocabulary as
    /// every other onboarding card.
    private var agentPreviewCard: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    AgentAvatarView(
                        mascotId: state.selectedAvatar,
                        name: previewName,
                        tint: agentColorFor(previewName),
                        diameter: 68,
                        monogramFontSize: 24,
                        borderWidth: 1.5
                    )
                    .shadow(
                        color: theme.accentColor.opacity(theme.isDark ? 0.24 : 0.16),
                        radius: 18,
                        x: 0,
                        y: 8
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(previewName)
                            .font(theme.font(size: 20, weight: .bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Image(systemName: state.selectedTemplate.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(LocalizedStringKey(state.selectedTemplate.label), bundle: .module)
                                .font(theme.font(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.22), lineWidth: 1))
                    }
                }

                Divider()
                    .overlay(theme.primaryBorder.opacity(0.45))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10, weight: .bold))
                        Text("Prompt preview", bundle: .module)
                            .textCase(.uppercase)
                            .font(theme.font(size: OnboardingMetrics.sectionLabelSize, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundColor(theme.tertiaryText)

                    Text(previewPrompt)
                        .font(theme.font(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(3)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(
                maxWidth: .infinity,
                minHeight: OnboardingMetrics.illustrationMaxHeight,
                alignment: .topLeading
            )
        }
    }

    private var previewName: String {
        state.trimmedName.isEmpty ? "Your agent" : state.trimmedName
    }

    private var previewPrompt: String {
        let trimmedPrompt = state.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            return "Start blank, or choose a starter to give your agent a clear role."
        }
        return trimmedPrompt
    }

    // MARK: - Starter chips

    private var starterRow: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Starter")
            HStack(spacing: 6) {
                ForEach(AgentStarterTemplate.allCases) { template in
                    templateChip(template)
                }
            }
        }
    }

    private func templateChip(_ template: AgentStarterTemplate) -> some View {
        let isSelected = state.selectedTemplate == template
        return Button {
            withAnimation(theme.animationQuick()) {
                state.applyTemplate(template)
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 16)
                Text(LocalizedStringKey(template.label), bundle: .module)
                    .font(theme.font(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OnboardingMetrics.selectableRowRadius, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: OnboardingMetrics.selectableRowRadius, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accentColor.opacity(0.45) : theme.inputBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Name")
            OnboardingTextField(
                label: "",
                placeholder: "e.g. Code Assistant",
                text: $state.name
            )
            .onChange(of: state.name) { _, newValue in
                if newValue != state.selectedTemplate.defaultName {
                    state.nameUserEdited = true
                }
            }
        }
    }

    // MARK: - System Prompt

    private var systemPromptField: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("System Prompt")
            OnboardingTextEditor(
                label: "",
                placeholder: "Instructions for this agent…",
                text: $state.systemPrompt,
                height: 100
            )
            .onChange(of: state.systemPrompt) { _, newValue in
                // Track edits so switching starters won't overwrite the
                // user's hand-tuned prompt. Equality with the active
                // template's prompt covers the no-op "I just re-selected
                // the same chip" case so we don't lock prematurely.
                if newValue != state.selectedTemplate.systemPrompt {
                    state.systemPromptUserEdited = true
                }
            }
        }
    }

    // MARK: - Avatar

    /// Six mascots, one chip each. The "no avatar" / monogram option lives
    /// in Configure post-onboarding — the create form always picks a
    /// colorful mascot so the row of cute dinos can read as the brand.
    private var avatarRow: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Avatar")
            HStack(spacing: 8) {
                ForEach(AgentMascot.allCases) { mascot in
                    avatarChip(mascotId: mascot.id)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private func avatarChip(mascotId: String?) -> some View {
        let isSelected = state.selectedAvatar == mascotId
        let diameter: CGFloat = 64
        let cellSize: CGFloat = 64
        return Button {
            withAnimation(theme.animationQuick()) {
                state.selectedAvatar = mascotId
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(theme.accentColor.opacity(0.22))
                        .frame(width: diameter + 18, height: diameter + 18)
                        .blur(radius: 8)
                }

                AgentAvatarView(
                    mascotId: mascotId,
                    name: state.name,
                    tint: agentColorFor(state.name),
                    diameter: diameter,
                    monogramFontSize: 18,
                    borderWidth: 1.5
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accentColor : Color.clear,
                            lineWidth: 2
                        )
                        .padding(-3)
                )
            }
            .frame(width: cellSize, height: cellSize)
            .scaleEffect(isSelected ? 1.0 : 0.96)
            .opacity(isSelected ? 1.0 : 0.85)
            .animation(theme.animationQuick(), value: isSelected)
        }
        .buttonStyle(.plain)
        .help(Text(mascotId.map { "Avatar: \($0)" } ?? "Initial", bundle: .module))
    }

    @ViewBuilder
    private func sectionLabel(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .textCase(.uppercase)
            .font(theme.font(size: OnboardingMetrics.sectionLabelSize, weight: .bold))
            .tracking(0.6)
            .foregroundColor(theme.tertiaryText)
    }
}

// MARK: - CTA

struct CreateAgentCTA: View {
    @ObservedObject var state: CreateAgentState
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(
            title: "Create Agent",
            action: { if state.saveAgent() { onContinue() } },
            isEnabled: state.canSave
        )
        .frame(width: OnboardingMetrics.ctaWidthCompact)
    }
}

// MARK: - Secondary

struct CreateAgentSecondary: View {
    let onSkip: () -> Void

    var body: some View {
        OnboardingTextButton(title: "Skip for now", action: onSkip)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCreateAgentView_Previews: PreviewProvider {
        static var previews: some View {
            let state = CreateAgentState()
            return VStack {
                CreateAgentBody(state: state).frame(height: 460)
                HStack {
                    CreateAgentSecondary(onSkip: {})
                    Spacer()
                    CreateAgentCTA(state: state, onContinue: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
