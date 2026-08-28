//
//  OnboardingCreateAgentView.swift
//  osaurus
//
//  Onboarding step 2 — Figma screen 2 ("What should your first Dino be
//  great at?"). Left column: hero title + subtitle + "Create your Dino"
//  pill. Right panel (green gradient tint): 96pt dino avatar with a
//  randomize badge, an editable name chip, and three selectable specialty
//  cards mapped onto the existing starter archetypes.
//
//  Split into:
//    - `CreateAgentState`: ObservableObject holding the selections + name
//      (lives in OnboardingView via @StateObject, so values survive slide
//      transitions).
//    - `CreateAgentStepView`: the full-window step layout.
//

import SwiftUI

// MARK: - Specialty

/// The three onboarding specialty cards, each backed by a starter archetype
/// that supplies the persisted system prompt.
enum OnboardingSpecialty: String, CaseIterable, Identifiable {
    case everyday
    case research
    case coding

    var id: String { rawValue }

    var template: AgentStarterTemplate {
        switch self {
        case .everyday: return .assistant
        case .research: return .researcher
        case .coding: return .coder
        }
    }

    var symbol: String {
        switch self {
        case .everyday: return "sparkles"
        case .research: return "magnifyingglass"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .everyday: return "Everyday helper"
        case .research: return "Research & writing"
        case .coding: return "Coding & development"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .everyday: return "A focused helper for questions, planning, and staying on track."
        case .research: return "A thoughtful partner for weighing sources and polishing prose."
        case .coding: return "A pragmatic pair-programmer for building and debugging code."
        }
    }
}

// MARK: - State

@MainActor
final class CreateAgentState: ObservableObject {
    /// Defaults to the general-purpose everyday helper so a user who just
    /// wants to move on can tap "Create your Dino" immediately.
    @Published var selectedSpecialty: OnboardingSpecialty = .everyday
    /// Starts on the brand-green dino, per the Figma frame.
    @Published var selectedAvatar: String? = AgentMascot.green.id
    /// Editable name, surfaced in the chip under the avatar. Independent of
    /// the specialty (the Figma name "Helper" doesn't change with the cards).
    @Published var name: String
    @Published var isSaving: Bool = false

    /// ID of the agent created by `saveAgent`. Read by
    /// `OnboardingView.pinSelectedBrainModel` so the new Dino's default
    /// model carries the brain choice too — the first chat itself lands on
    /// the built-in Orchestrator, with this agent one click away in the
    /// switcher.
    @Published private(set) var createdAgentId: UUID?

    /// The Figma default dino name.
    static var defaultName: String { L("Helper") }

    init() {
        name = Self.defaultName
    }

    var selectedTemplate: AgentStarterTemplate { selectedSpecialty.template }

    /// Always savable — selections always have a default and the name falls
    /// back to the default, so the CTA is enabled immediately.
    var canSave: Bool { !isSaving }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolved name actually persisted: the user's text, or the default
    /// when they've left it blank.
    var resolvedName: String {
        trimmedName.isEmpty ? Self.defaultName : trimmedName
    }

    /// Rolls the avatar to a different mascot — the randomize badge on the
    /// 96pt avatar.
    func randomizeAvatar() {
        let pool = AgentMascot.allCases.filter { $0.id != selectedAvatar }
        selectedAvatar = (pool.randomElement() ?? .green).id
    }

    /// Persists the agent and returns whether save succeeded. The caller is
    /// responsible for advancing the flow afterwards.
    ///
    /// The system prompt is derived from the chosen specialty's archetype and
    /// the description from its tagline; both are editable later in Settings.
    ///
    /// Idempotent: if the user navigates back from a later onboarding
    /// step and re-fires the CTA, the previously-created agent's id is
    /// returned as success without spawning a duplicate `AgentManager`
    /// entry.
    @discardableResult
    func saveAgent() -> Bool {
        if createdAgentId != nil { return true }
        guard !isSaving else { return false }
        isSaving = true
        var agent = AgentManager.newCustomAgentRecord(
            name: resolvedName,
            description: selectedTemplate.tagline,
            systemPrompt: selectedTemplate.systemPrompt
        )
        agent.toolSelectionMode = .auto
        agent.avatar = selectedAvatar
        AgentManager.shared.add(agent)
        createdAgentId = agent.id
        isSaving = false
        return true
    }
}

// MARK: - Step view

struct CreateAgentStepView: View {
    @ObservedObject var state: CreateAgentState
    let onContinue: () -> Void

    @FocusState private var nameFocused: Bool
    /// Width the name field is pinned to, measured from a hidden copy of the
    /// displayed text so focusing never nudges the chip's footprint.
    @State private var nameFieldWidth: CGFloat = 0
    /// Accumulated rotation of the randomize badge glyph — a half-turn per
    /// roll so repeat taps keep spinning the same way.
    @State private var badgeSpin: Double = 0

    private var selectedMascot: AgentMascot {
        state.selectedAvatar.flatMap(AgentMascot.init(rawValue:)) ?? .green
    }

    var body: some View {
        OnboardingStepLayout {
            leftColumn
        } right: {
            rightPanel
        }
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
    }

    // MARK: Left column

    /// Staggered cascade: title → subtitle → CTA.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What should your first Dino be great at?", bundle: .module)
                .font(OnboardingTypography.heroTitle)
                .tracking(0.4)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingEntrance(0)

            Spacer().frame(height: 16)

            Text("Change its specialty or create another Dino anytime.", bundle: .module)
                .font(OnboardingTypography.subtitle)
                .foregroundColor(OnboardingPalette.labelSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingEntrance(1)

            Spacer().frame(height: 40)

            OnboardingPillButton(
                title: "Create your Dino",
                style: .primary,
                size: .large,
                isEnabled: state.canSave,
                action: { if state.saveAgent() { onContinue() } }
            )
            .onboardingEntrance(2)
        }
    }

    // MARK: Right panel

    /// Figma "Right": 40pt padding, avatar group pinned to the top and the
    /// specialty cards pinned to the bottom (space-between).
    private var rightPanel: some View {
        OnboardingRightPanel(gradientTint: OnboardingPalette.createGradientGreen) {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    avatarBlock
                        .onboardingEntrance(0, scaleFrom: 0.96)
                    nameChip
                        .onboardingEntrance(1)
                }
                Spacer(minLength: 24)
                specialtyCards
            }
            .padding(40)
        }
    }

    // MARK: Avatar + randomize badge

    private var avatarBlock: some View {
        ZStack(alignment: .bottomTrailing) {
            AgentAvatarView(
                mascotId: state.selectedAvatar,
                name: state.resolvedName,
                tint: selectedMascot.color,
                diameter: 96,
                monogramFontSize: 34,
                borderWidth: 2,
                bleedsToEdge: true
            )
            .id(state.selectedAvatar)
            .transition(.scale(scale: 0.85).combined(with: .opacity))

            randomizeBadge
        }
        .animation(OnboardingMotion.bouncy, value: state.selectedAvatar)
    }

    /// 24pt dark circular badge on the avatar's bottom-trailing edge that
    /// rolls a different dino color (Figma "Arrow Buttons"). The glyph does
    /// a half-turn with each roll.
    private var randomizeBadge: some View {
        Button {
            badgeSpin -= 180
            state.randomizeAvatar()
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.75))
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(OnboardingPalette.labelPrimary)
                    .rotationEffect(.degrees(badgeSpin))
                    .animation(OnboardingMotion.snappy, value: badgeSpin)
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .localizedHelp("Pick a random look")
    }

    // MARK: Name chip

    /// Editable name in a dark capsule chip ("Helper ✎"). Tapping anywhere on
    /// the chip focuses the field; the pencil hints at editability.
    private var nameChip: some View {
        HStack(spacing: 8) {
            ZStack {
                nameWidthDriver.hidden()

                TextField(text: $state.name, prompt: defaultNameText) { defaultNameText }
                    .textFieldStyle(.plain)
                    .font(OnboardingTypography.nameChip)
                    .foregroundColor(OnboardingPalette.labelPrimary)
                    .multilineTextAlignment(.center)
                    .frame(width: nameFieldWidth + 4)
                    .focused($nameFocused)
            }
            .onPreferenceChange(NameWidthKey.self) { nameFieldWidth = $0 }

            Image(systemName: "pencil")
                .font(.system(size: 14))
                .foregroundColor(OnboardingPalette.labelPrimary)
                .opacity(nameFocused ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(OnboardingPalette.fill3))
        .overlay(
            Capsule().strokeBorder(
                nameFocused ? OnboardingPalette.labelSecondary : OnboardingPalette.fill5,
                lineWidth: 1
            )
        )
        .animation(.easeOut(duration: 0.15), value: nameFocused)
        .contentShape(Capsule())
        .onTapGesture { nameFocused = true }
    }

    private var defaultNameText: Text {
        Text(LocalizedStringKey(CreateAgentState.defaultName), bundle: .module)
    }

    /// Invisible mirror of the field's displayed text, styled identically,
    /// used purely to measure the width the editable field should be pinned
    /// to (see `nameFieldWidth`).
    private var nameWidthDriver: some View {
        (state.trimmedName.isEmpty ? defaultNameText : Text(state.name))
            .font(OnboardingTypography.nameChip)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: NameWidthKey.self, value: proxy.size.width)
                }
            )
    }

    // MARK: Specialty cards

    private var specialtyCards: some View {
        VStack(spacing: 16) {
            ForEach(
                Array(OnboardingSpecialty.allCases.enumerated()), id: \.element.id
            ) { index, specialty in
                OnboardingSelectableCard(
                    symbol: specialty.symbol,
                    title: specialty.title,
                    caption: specialty.caption,
                    isSelected: state.selectedSpecialty == specialty
                ) {
                    // `smooth`: selection recolors borders/fills across the
                    // card stack — overshoot here reads as flicker.
                    withAnimation(OnboardingMotion.smooth) {
                        state.selectedSpecialty = specialty
                    }
                }
                .onboardingEntrance(2 + index)
            }
        }
    }
}

// MARK: - Name Field Width Measurement

/// Carries the measured width of the hidden name mirror up to the step view
/// so the editable field can be pinned to a focus-stable width.
private struct NameWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCreateAgentView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                OnboardingPalette.windowBackground
                CreateAgentStepView(state: CreateAgentState(), onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
    }
#endif
